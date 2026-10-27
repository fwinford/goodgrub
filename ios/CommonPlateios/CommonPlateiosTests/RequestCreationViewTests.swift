import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreationViewTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Validation timing and presentation

    func testAllEmptyRequestDraftDisablesSubmission() {
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: RequestFoodFormDraft(),
            submissionError: nil,
            isCreating: false
        ))
    }

    func testEachMissingRequiredRequestValueDisablesSubmission() throws {
        let complete = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        var missingDiningSpot = complete
        missingDiningSpot.selectedDiningSpot = nil
        var missingMealDetail = complete
        missingMealDetail.mealEntries[0] = "  "
        // W4-R4: a second selected swipe whose own field is still blank is
        // just as incomplete as the first one being blank.
        var missingSecondMealDetail = complete
        missingSecondMealDetail.mealSwipes = 2

        for draft in [missingDiningSpot, missingMealDetail, missingSecondMealDetail] {
            XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
                draft: draft,
                submissionError: nil,
                isCreating: false
            ))
        }
    }

    func testCompletedRequestDraftEnablesSubmissionForBothTimingSelections() throws {
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))

        draft.timing = .later
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
    }

    func testMalformedNonemptyEmailDoesNotDisableRequestSubmission() {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
    }

    func testInFlightAndExistingLifecycleBlockDisableRequestSubmission() {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: true
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: .ambiguous,
            isCreating: false
        ))
    }

    func testInvalidFieldRemainsQuietDuringInitialTyping() {
        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                menuPath: .mealExchange,
                timing: .asap,
                mealSwipes: 1,
                mealEntries: ["", "", "", "", ""]
            ),
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        let presentation = RequestFoodValidationPresentation()

        XCTAssertEqual(errors.map(\.error), [.missingMealDetail(index: 0)])
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)
    }

    func testProductionFocusTransitionRevealsOnlyTheExitedInvalidRequestField() {
        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: nil,
                menuPath: .mealExchange,
                timing: .later,
                mealSwipes: 1,
                mealEntries: ["", "", "", "", ""],
                diningDollarsText: "26.00"
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()

        // The empty Meal item is incomplete, not invalid: leaving it reveals
        // nothing. The entered out-of-bounds amount is invalid: leaving it does.
        presentation.handleFocusTransition(
            from: .mealDetail(index: 0),
            to: .diningDollars,
            errors: errors
        )
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)

        presentation.handleFocusTransition(
            from: .diningDollars,
            to: nil,
            errors: errors
        )
        XCTAssertEqual(
            presentation.visibleErrors(from: errors).map(\.field),
            [.diningDollars]
        )
    }

    func testRequestSubmitRejectsEveryErrorWithoutInvokingSubmission() async throws {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T15:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["", "", "", "", ""]
        )
        let now = try date("2026-07-28T16:00:00.000Z")
        var submissionCount = 0

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        let visible = result.presentation.visibleErrors(from: errors)

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        // The empty Meal item still blocks submission and still receives
        // focus, but it is incomplete rather than invalid, so it is not shown.
        XCTAssertEqual(
            visible.map(\.field),
            [.diningSpot, .pickupSchedule]
        )
        XCTAssertEqual(result.firstInvalidTextField, .mealDetail(index: 0))
    }

    func testPresentedRequestErrorUpdatesLiveWhileNeverPresentedFieldsStayQuiet() {
        func errors(diningDollars: String) -> [RequestFoodFieldError] {
            RequestFoodFormValidator.validate(
                draft: RequestFoodFormDraft(
                    selectedDiningSpot: nil,
                    menuPath: .diningDollars,
                    timing: .asap,
                    mealSwipes: 1,
                    orderDetails: "Fries",
                    diningDollarsText: diningDollars
                ),
                isScheduledWindowValid: true,
                isScheduledTimingAvailable: true
            )
        }
        let initial = errors(diningDollars: "50.01")
        var presentation = RequestFoodValidationPresentation()
        presentation.handleFocusTransition(
            from: .diningDollars,
            to: nil,
            errors: initial
        )

        XCTAssertTrue(presentation.visibleErrors(from: errors(diningDollars: "10.00")).isEmpty)

        let invalidAgain = errors(diningDollars: "60")
        XCTAssertEqual(
            presentation.visibleErrors(from: invalidAgain).map(\.field),
            [.diningDollars],
            "Dining spot never presented an error, so it must stay quiet"
        )

        // Clearing a previously presented invalid amount back to empty returns
        // it to neutral: empty is incomplete, and incomplete is never shown.
        let emptied = errors(diningDollars: "")
        XCTAssertEqual(
            emptied.first { $0.field == .diningDollars }?.error,
            .missingDiningDollars
        )
        XCTAssertNil(presentation.visibleError(for: .diningDollars, from: emptied))
    }

    func testPresentedDiningPickerErrorClearsAndReappearsWithSelection() {
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
        let initialErrors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(initialErrors)
        XCTAssertNotNil(presentation.visibleError(for: .diningSpot, from: initialErrors))

        draft.selectedDiningSpot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
        let correctedErrors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertNil(presentation.visibleError(for: .diningSpot, from: correctedErrors))

        draft.selectedDiningSpot = nil
        XCTAssertNotNil(presentation.visibleError(for: .diningSpot, from: initialErrors))
    }

    func testValidRequestSubmitInvokesSubmissionOnceWithNormalizedPayload() async throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let preferredTime = try date("2026-07-28T17:00:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "  Jasper Kane Cafe  ", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: preferredTime,
            mealSwipes: 1,
            mealEntries: ["  Chicken bowl \n", "", "", "", ""]
        )
        var payloads: [CreateRequestPayload] = []

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            payloads.append(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.vendor, "Jasper Kane Cafe")
        XCTAssertEqual(payloads.first?.mealItems, ["Chicken bowl"])
        XCTAssertEqual(payloads.first?.menuPath, .mealExchange)
        XCTAssertEqual(payloads.first?.timing.rawValue, "scheduled")
        XCTAssertEqual(payloads.first?.windowStart, preferredTime)
    }

    func testRequestBackendFailurePreservesActualDraftAndTimingSelection() async throws {
        enum SimulatedBackendFailure: Error { case rejected }

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
        let originalDraft = draft
        var submissionCount = 0

        do {
            _ = try await RequestFoodView.orchestrateSubmission(
                draft: draft,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { _ in
                submissionCount += 1
                throw SimulatedBackendFailure.rejected
            }
            XCTFail("The simulated backend failure must escape the production seam")
        } catch {
            XCTAssertTrue(error is SimulatedBackendFailure)
        }
        _ = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "INVALID_REQUEST", message: "backend detail")
        )

        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.timing, .later)
        XCTAssertEqual(draft.preferredPickupTime, originalDraft.preferredPickupTime)
    }

    func testPresentedSchedulingErrorRemainsRenderableWhenSchedulingBecomesUnavailable() async throws {
        let availableNow = try date("2026-07-28T22:00:00.000Z")
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: availableNow,
            calendar: utcCalendar
        ))
        XCTAssertFalse(RequestFoodView.isScheduledTimingAvailable(
            now: unavailableNow,
            calendar: utcCalendar
        ))

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let unavailableErrors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(
            result.presentation.visibleError(for: .pickupSchedule, from: unavailableErrors)?.error,
            .scheduledTimingUnavailable
        )

        draft.timing = .asap
        let asapErrors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        XCTAssertNil(result.presentation.visibleError(for: .pickupSchedule, from: asapErrors))

        draft.timing = .later
        XCTAssertEqual(
            result.presentation.visibleError(for: .pickupSchedule, from: unavailableErrors)?.error,
            .scheduledTimingUnavailable
        )
    }

    /// While scheduling is still open, a bad start is a bad start: the picker is
    /// on screen, so the instruction is to pick a different time.
    func testInvalidStartWhileSchedulingIsOpenKeepsTheChooseAPickupTimeMessage() throws {
        let now = try date("2026-07-28T22:00:00.000Z")
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(
            RequestFoodView.availableTimingOptions(now: now, calendar: utcCalendar),
            RequestTiming.allCases
        )

        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                menuPath: .mealExchange,
                timing: .later,
                mealSwipes: 1,
                mealEntries: ["Chicken bowl", "", "", "", ""]
            ),
            // A start in the past: correctable, because a valid one still exists.
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )

        XCTAssertEqual(errors.map(\.field), [.pickupSchedule])
        XCTAssertEqual(errors.first?.error, .invalidScheduledTime)
        XCTAssertEqual(
            errors.first?.message,
            "Choose a pickup time later today."
        )
    }

    /// The lapsed selection itself. Nothing is rewritten for the requester —
    /// the draft still says Later — but the message stops pointing at a picker
    /// that no longer exists and names the one move left.
    func testLapsedLaterSelectionNamesASAPInsteadOfADepartedPicker() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
        let originalDraft = draft

        XCTAssertFalse(RequestFoodView.isScheduledTimingAvailable(
            now: unavailableNow,
            calendar: utcCalendar
        ))
        // The picker is gone, and with it the only control this state could
        // have asked the requester to use.
        XCTAssertEqual(
            RequestFoodView.availableTimingOptions(now: unavailableNow, calendar: utcCalendar),
            [.asap]
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        // Nothing was switched on their behalf.
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.timing, .later)

        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        let visible = try XCTUnwrap(
            result.presentation.visibleError(for: .pickupSchedule, from: errors)
        )
        XCTAssertEqual(visible.error, .scheduledTimingUnavailable)
        XCTAssertEqual(
            visible.message,
            "Scheduling is closed for today. Choose ASAP to post this request now."
        )
        XCTAssertNotEqual(visible.error, .invalidScheduledTime)
        XCTAssertFalse(
            visible.message.contains("Choose a pickup time later today.")
        )

        // The completeness gate stays open: the draft is complete, just invalid,
        // and the requester has to be able to tap Submit to hear why.
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))

        // One statement about the closed window, not two.
        XCTAssertFalse(RequestFoodView.showsScheduledUnavailableNotice(
            isScheduledTimingAvailable: false,
            visibleScheduleError: .scheduledTimingUnavailable
        ))
        // An ASAP draft still gets the plain footnote: it is the only thing
        // explaining why Later is missing from the picker.
        XCTAssertTrue(RequestFoodView.showsScheduledUnavailableNotice(
            isScheduledTimingAvailable: false,
            visibleScheduleError: nil
        ))
        XCTAssertTrue(
            RequestFoodView.lapsedScheduledTimingNotice
                .hasPrefix(RequestFoodView.scheduledClosedForToday)
        )
        XCTAssertTrue(
            RequestFoodView.scheduledUnavailableNotice
                .hasPrefix(RequestFoodView.scheduledClosedForToday)
        )
    }

    /// A rejection with no text field to focus used to be silent. The tap now
    /// leaves something visible next to the button that was tapped.
    func testLocalRejectionWithNoFocusableFieldShowsTheSubmitAdjacentPointer() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertNil(result.firstInvalidTextField)
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(for: result))
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(
            isPresenting: true,
            submissionError: nil
        ))
        XCTAssertEqual(
            RequestFoodView.localRejectionPointerNotice,
            "Check the highlighted fields above."
        )
        // It points at the adjacent errors; it never restates or replaces them.
        XCTAssertNil(RequestFoodView.submissionSectionPresentation(for: nil))
    }

    /// Focus is its own answer to the tap, so the generic pointer stays away
    /// from every rejection that can move it.
    func testFocusableRejectionFocusesTheFieldWithoutTheGenericPointer() async throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: now,
            mealSwipes: 1,
            // A focusable rejection: the one active meal-detail field is blank.
            mealEntries: ["   ", "", "", "", ""]
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(result.firstInvalidTextField, .mealDetail(index: 0))
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(for: result))
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(
            isPresenting: false,
            submissionError: nil
        ))
    }

    /// Choosing ASAP is the correction the message asks for, so it has to be a
    /// real way out: the scheduling error goes, everything else the requester
    /// typed stays, and the submission proceeds normally.
    func testChoosingASAPClearsTheLapsedErrorAndPermitsSubmission() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )

        let rejected = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in }
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(for: rejected))

        draft.timing = .asap

        let correctedErrors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: draft.selectedDiningSpot,
                menuPath: .mealExchange,
                timing: draft.timing,
                mealSwipes: draft.mealSwipes,
                mealEntries: draft.mealEntries
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        XCTAssertTrue(correctedErrors.isEmpty)
        // Presentation history is unchanged, and there is simply nothing left
        // for it to reveal.
        XCTAssertNil(
            rejected.presentation.visibleError(for: .pickupSchedule, from: correctedErrors)
        )

        // Only the timing moved.
        XCTAssertEqual(draft.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(draft.mealEntries[0], "Chicken bowl")
        XCTAssertEqual(draft.preferredPickupTime, try date("2026-07-28T23:00:00.000Z"))

        var submitted: CreateRequestPayload?
        let accepted = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: rejected.presentation
        ) { payload in
            submitted = payload
        }

        XCTAssertTrue(accepted.didSubmit)
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(for: accepted))
        XCTAssertEqual(submitted?.timing, .asap)
        XCTAssertNil(submitted?.windowStart)
    }

    /// The pointer is local-only. Anything the backend decided keeps the
    /// submission section to itself, including the ambiguous outcome that
    /// withdraws submission entirely.
    func testBackendAndAmbiguousErrorsKeepTheirOwnSubmitAdjacentMessages() {
        for error in [
            RequestCreatePresentationError.invalidRequest,
            .requestLimitReached,
            .publicActionsPaused,
            .creationFailed,
            .operationInProgress,
            .ambiguous
        ] {
            let presentation = RequestFoodView.submissionSectionPresentation(for: error)
            XCTAssertEqual(presentation?.message, error.message, "\(error)")
            XCTAssertNotEqual(
                presentation?.message,
                RequestFoodView.localRejectionPointerNotice,
                "\(error)"
            )
            // Even if a stale local rejection were still flagged, a backend
            // answer takes the section.
            XCTAssertFalse(
                RequestFoodView.showsLocalRejectionPointer(
                    isPresenting: true,
                    submissionError: error
                ),
                "\(error)"
            )
        }

        XCTAssertTrue(RequestFoodView.showsReturnHomeAction(for: .ambiguous))
        XCTAssertFalse(RequestFoodView.allowsSubmission(after: .ambiguous))
    }

    func testProgrammaticRequestFocusChangesCannotSubmitOrRevealSiblings() {
        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: nil,
                menuPath: .mealExchange,
                timing: .asap,
                mealSwipes: 1,
                mealEntries: ["Chicken bowl", "", "", "", ""],
                diningDollarsText: "26.00"
            ),
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        let submissionCount = 0

        presentation.handleFocusTransition(from: nil, to: .diningDollars, errors: errors)
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)

        presentation.handleFocusTransition(from: .diningDollars, to: nil, errors: errors)
        XCTAssertEqual(presentation.visibleErrors(from: errors).map(\.field), [.diningDollars])
        XCTAssertEqual(submissionCount, 0)
    }

    func testASAPPayloadTrimsValuesAndOmitsWindowFields() throws {
        let payload = try RequestFoodView.makePayload(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "  Jasper Kane Cafe  ", address: nil),
                menuPath: .mealExchange,
                timing: .asap,
                preferredPickupTime: Date(timeIntervalSince1970: 0),
                mealSwipes: 2,
                mealEntries: ["  Chicken bowl \n", "  Side salad  ", "", "", ""]
            ),
            now: Date(timeIntervalSince1970: 1_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.vendor, "Jasper Kane Cafe")
        // Every structured entry is trimmed, exactly as the single flat field
        // was before W4-R4.
        XCTAssertEqual(payload.mealItems, ["Chicken bowl", "Side salad"])
        XCTAssertEqual(payload.timing.rawValue, "asap")
        XCTAssertNil(payload.windowStart)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("windowStart"))
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }

    /// The requester picks a start and nothing else. The backend derives the
    /// end from it, so the payload must carry no end at all — the create shape
    /// is strict and refuses one.
    func testScheduledPayloadSendsOnlyTheSelectedStart() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let preferredTime = try date("2026-07-28T17:00:00.000Z")

        let payload = try RequestFoodView.makePayload(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                menuPath: .mealExchange,
                timing: .later,
                preferredPickupTime: preferredTime,
                mealSwipes: 2,
                mealEntries: ["Chicken bowl", "Side salad", "", "", ""]
            ),
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.timing.rawValue, "scheduled")
        XCTAssertEqual(payload.windowStart, preferredTime)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertTrue(json.keys.contains("windowStart"))
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }

    func testLatestScheduledStartSitsAtTheDayBoundaryCutoff() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let latestStart = try XCTUnwrap(
            RequestFoodView.latestScheduledStart(on: now, calendar: utcCalendar)
        )
        let dayEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: now, calendar: utcCalendar)
        )

        XCTAssertEqual(latestStart, try date("2026-07-28T23:30:00.000Z"))
        XCTAssertEqual(
            utcCalendar.dateComponents([.minute], from: latestStart, to: dayEnd).minute,
            RequestFoodView.scheduledStartCutoffMinutesBeforeDayEnd
        )
        XCTAssertTrue(
            RequestFoodView.isValidScheduledWindow(
                startingAt: latestStart,
                now: now,
                calendar: utcCalendar
            )
        )
    }

    func testScheduledWindowPastLatestStartIsRejected() throws {
        let now = try date("2026-07-28T16:00:00.000Z")

        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                draft: RequestFoodFormDraft(
                    selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                    menuPath: .mealExchange,
                    timing: .later,
                    preferredPickupTime: try date("2026-07-28T23:31:00.000Z"),
                    mealSwipes: 2,
                    mealEntries: ["Chicken bowl", "Side salad", "", "", ""]
                ),
                now: now,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .invalidScheduledTime)
        }
    }

    func testKnownBackendErrorsMapToStudentFacingStates() {
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "INVALID_REQUEST", message: "backend detail")
            ),
            .invalidRequest
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "REQUEST_LIMIT_REACHED", message: "backend detail")
            ),
            .requestLimitReached
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "PUBLIC_ACTIONS_PAUSED", message: "backend detail")
            ),
            .publicActionsPaused
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "REQUEST_CREATION_FAILED", message: "backend detail")
            ),
            .creationFailed
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.ambiguousCreateOutcome(
                    underlying: URLError(.networkConnectionLost)
                )
            ),
            .ambiguous
        )
    }

    func testStructuredBackendFailureUsesSubmitSectionPresentation() {
        let error = RequestCreatePresentationError.map(
            RequestServiceError.serverError(
                code: "REQUEST_CREATION_FAILED",
                message: "backend detail"
            )
        )
        let presentation = RequestFoodView.submissionSectionPresentation(for: error)

        XCTAssertEqual(presentation?.error, .creationFailed)
        XCTAssertEqual(
            presentation?.message,
            "We couldn’t post your request. Please try again in a moment."
        )
        XCTAssertFalse(presentation?.showsReturnHomeAction ?? true)
    }

    func testAmbiguousCreationUsesTheSameSubmitSectionPresentation() {
        let error = RequestCreatePresentationError.map(
            RequestServiceError.ambiguousCreateOutcome(
                underlying: URLError(.timedOut)
            )
        )
        let presentation = RequestFoodView.submissionSectionPresentation(for: error)

        XCTAssertEqual(presentation?.error, .ambiguous)
        XCTAssertEqual(
            presentation?.message,
            "\(AppBrand.name) couldn’t confirm whether your request posted."
        )
        XCTAssertTrue(presentation?.showsReturnHomeAction ?? false)
    }

    func testSubmitSectionFailurePresentationPreservesDraftAndPickupSelection() async throws {
        enum SimulatedBackendFailure: Error { case rejected }

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
        let originalDraft = draft

        do {
            _ = try await RequestFoodView.orchestrateSubmission(
                draft: draft,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { _ in
                throw SimulatedBackendFailure.rejected
            }
            XCTFail("The simulated backend failure must escape the production seam")
        } catch {
            XCTAssertTrue(error is SimulatedBackendFailure)
        }

        let sectionPresentation = RequestFoodView.submissionSectionPresentation(
            for: .creationFailed
        )
        XCTAssertNotNil(sectionPresentation)
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.selectedDiningSpot, originalDraft.selectedDiningSpot)
        XCTAssertEqual(draft.timing, .later)
        XCTAssertEqual(draft.preferredPickupTime, originalDraft.preferredPickupTime)
    }

    func testLocalFieldErrorsDoNotEnterSubmitSectionPresentation() {
        let errors = RequestFoodFormValidator.validate(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: nil,
                menuPath: .mealExchange,
                timing: .later,
                mealSwipes: 1,
                mealEntries: ["", "", "", "", ""]
            ),
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var validationPresentation = RequestFoodValidationPresentation()
        validationPresentation.presentAll(errors)

        XCTAssertEqual(
            validationPresentation.visibleErrors(from: errors).map(\.field),
            [.diningSpot, .pickupSchedule]
        )
        XCTAssertNil(RequestFoodView.submissionSectionPresentation(for: nil))
    }

    /// The web form asserts this same sentence against
    /// `REQUEST_POSTING_PAUSED_MESSAGE` (`src/client/new-request.test.ts`).
    /// Both halves must exist, or the two clients can drift apart unnoticed —
    /// which is exactly what happened when the iOS pause tests were removed.
    @MainActor
    func testPausedCreateUsesTheLockedSentenceSharedWithTheWebForm() {
        XCTAssertEqual(
            RequestFoodView.pauseNotice,
            "Posting a meal request is temporarily unavailable."
        )
        XCTAssertEqual(
            RequestCreatePresentationError.publicActionsPaused.message,
            "Posting a meal request is temporarily unavailable."
        )
    }

    // MARK: - Expiration copy

    /// Under the revised W3-R1 presentation contract the three-hour rule is
    /// explained once, at the timing choice
    /// (`RequestFoodView.formExpirationNotice`); the post-submit success
    /// screen no longer restates it under any name. Scoped to the
    /// `successView` declaration itself — not a whole-file symbol-name ban —
    /// so this guards the actual success-state presentation rather than a
    /// particular former property or function name, and would still catch a
    /// differently-named reintroduction of the same policy text.
    @MainActor
    func testSuccessViewDoesNotReintroduceTheExpirationPolicy() throws {
        let successViewSource = try successViewDeclarationSource()

        // W4-D2: the confirmation state directly replaces Posting in the
        // same centered locus with the actual created card and approved
        // success copy, and carries no CTA — the dwell/native-dismissal
        // sequence is the only continuation.
        XCTAssertTrue(successViewSource.contains("Self.successMessage"))
        XCTAssertTrue(successViewSource.contains("Self.successGuidance"))
        XCTAssertFalse(successViewSource.contains("Button("))

        // No duration or expiration wording of any kind belongs on this
        // screen; that explanation lives solely at the timing choice.
        let lowercased = successViewSource.lowercased()
        for forbidden in ["hour", "expir", "visible to helpers"] {
            XCTAssertFalse(
                lowercased.contains(forbidden),
                "success view must not restate timing/expiration policy: found \"\(forbidden)\""
            )
        }
    }

    /// W4-R2 removed a stale promise that every new request would appear
    /// inline on Home. CP2 guidance lives only in the existing Success→Home
    /// continuity, and only for a participant's first post on this install.
    @MainActor
    func testSuccessGuidanceLivesInTheExistingContinuityPresentation() throws {
        let source = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("successSubtitle"))
        XCTAssertFalse(source.contains("It\u{2019}ll appear on Home"))
        XCTAssertFalse(source.contains("Your Request."))

        XCTAssertEqual(RequestCreationContinuityView.successMessage, "Request posted!")
        XCTAssertEqual(
            RequestCreationContinuityView.successGuidance,
            "We'll let you know when a student places your order."
        )
        XCTAssertEqual(
            RequestCreationContinuityView.successAnnouncement,
            "Request posted! We'll let you know when a student places your order."
        )

        let successViewSource = try successViewDeclarationSource()
        XCTAssertTrue(successViewSource.contains("Text(Self.successMessage)"))
        XCTAssertTrue(successViewSource.contains("Text(Self.successGuidance)"))
        XCTAssertTrue(successViewSource.contains("if isFirstRequest {\n                            Text(Self.successGuidance)"))
        XCTAssertTrue(successViewSource.contains("argument: isFirstRequest ? Self.successAnnouncement : Self.successMessage"))
        XCTAssertTrue(successViewSource.contains(".accessibilityElement(children: .combine)"))
    }

    @MainActor
    func testFinalSuccessDwellHapticFenceAndOpticalPlacement() throws {
        // W4-R2 final READY contract: supersedes every earlier ~1.7-second
        // requirement with ~1.6 seconds. W4-D2 preserves this exact total —
        // it only splits it between the settle and landing sub-phases, never
        // introducing a new, separate total dwell, and never lengthening it
        // for Reduce Motion either. CP2's first-request plan is proven in
        // `CP2FirstRequestGuidanceTests`.
        XCTAssertEqual(RequestFoodView.successDwellDuration, .milliseconds(1600))
        for plan in [
            RequestCreationContinuityMotionPlan.standard,
            RequestCreationContinuityMotionPlan.reducedMotion,
        ] {
            XCTAssertEqual(plan.settleDwell + plan.landingDuration, plan.totalDuration)
            XCTAssertEqual(plan.totalDuration, RequestCreationContinuityMotionPlan.successDwellDuration)
        }

        let successViewSource = try successViewDeclarationSource()
        XCTAssertTrue(successViewSource.contains("guard !hasAcknowledged else { return }"))
        XCTAssertEqual(
            successViewSource.components(separatedBy: "CommonPlateHaptics.success()").count - 1,
            1,
            "exactly one success haptic — the landing sub-phase must not add a second one"
        )
        XCTAssertEqual(
            successViewSource.components(separatedBy: "UIAccessibility.post(").count - 1,
            1,
            "exactly one VoiceOver announcement for the whole sequence"
        )
        XCTAssertTrue(successViewSource.contains(".padding(.bottom, 60)"))
        XCTAssertTrue(successViewSource.contains("try await Task.sleep(for: plan.settleDwell)"))
        XCTAssertTrue(successViewSource.contains("try await Task.sleep(for: plan.landingDuration)"))
        // Retirement is addressed to this exact continuity, on both the
        // completed and the interrupted ending.
        XCTAssertEqual(
            successViewSource.components(separatedBy: "onFinished(continuity.id)").count - 1,
            2,
            "the sequence must retire its own continuity when it completes and when it goes away"
        )

        // W4-D2: the authoritative CREATED path never shows a generic
        // checkmark, meal-swipe ticket, or invented icon — the actual
        // created card is the entire visual.
        XCTAssertFalse(successViewSource.contains("statusIcon(systemName: \"checkmark\")"))

        // The Request Food screen's own Success state is now a silent
        // handoff: no second copy, card, icon, haptic, or announcement
        // underneath the overlay.
        let handoffSource = try requestFoodSuccessHandoffSource()
        XCTAssertFalse(handoffSource.contains("Text("))
        XCTAssertFalse(handoffSource.contains("RequestCardView("))
        XCTAssertFalse(handoffSource.contains("CommonPlateHaptics"))
        XCTAssertFalse(handoffSource.contains("UIAccessibility.post("))
        XCTAssertTrue(handoffSource.contains("onExit()"))
    }

    /// Bounded extraction of `RequestFoodView`'s own Success handoff state,
    /// matching `successViewDeclarationSource()`'s pattern.
    private func requestFoodSuccessHandoffSource() throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        let startMarker = "private var successHandoffView: some View {"
        let endMarker = "static let successMessage"

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after successHandoffView")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testMenuSelectionPrecedesTimingWithoutHelperAndTimingKeepsExplanation() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var requestForm: some View {"))
        let end = try XCTUnwrap(
            source.range(
                of: "// MARK: - W4-R2 approved `Requester / Form Field` controls",
                range: start.upperBound..<source.endIndex
            )
        )
        let requestFormSource = String(source[start.lowerBound..<end.lowerBound])
        // W4-R4: pickup name is removed from the form entirely, and the
        // menu-dependent resource fields take its place ahead of Timing.
        XCTAssertFalse(requestFormSource.contains("pickupNameLabel"))
        XCTAssertFalse(requestFormSource.contains("Name on order"))
        let menuPath = try XCTUnwrap(requestFormSource.range(of: "menuPathLabelText"))
        let timing = try XCTUnwrap(requestFormSource.range(of: "RequesterTimingHeader("))

        XCTAssertLessThan(menuPath.lowerBound, timing.lowerBound)
        XCTAssertFalse(requestFormSource.contains("Enter the name you want"))
        XCTAssertFalse(requestFormSource.contains("placed under"))
    }

    func testDiningDollarsFieldsUseAcceptedPresentation() throws {
        // 2026-09-20 HQ decision superseded the per-field placeholder with
        // the collapsed-container's own empty-state label.
        XCTAssertEqual(RequestFoodView.mealDetailPlaceholder, "What are you ordering?")
        XCTAssertEqual(RequestFoodView.diningDollarsLabel, "Dining Dollars")
        XCTAssertEqual(RequestFoodView.diningDollarsRequiredLabel, "Dining Dollars")
        XCTAssertEqual(RequestFoodView.screenshotAssistanceOptionalLabel, "Optional")

        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("trailingLabel: Self.screenshotAssistanceOptionalLabel"))
        XCTAssertFalse(source.contains("Dining Dollars (optional)"))
        XCTAssertFalse(source.contains("What would you like for this meal swipe?"))
        XCTAssertFalse(source.contains("Leave empty if you don’t need any Dining Dollars."))
        XCTAssertFalse(source.contains("An estimate, not a guaranteed total."))
    }

    func testMealEditorUsesCanonicalSeparateLabelAndControlHierarchy() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("e.g. Chicken Wings"))
        XCTAssertTrue(source.contains("e.g. Buffalo sauce, chips, fountain drink"))
        XCTAssertTrue(source.contains("screenshotProvenance.mealItemNames.contains(index)"))
        XCTAssertTrue(source.contains("screenshotProvenance.mealItemDetails.contains(index)"))
        XCTAssertFalse(source.contains("screenshotProvenance.mealEntries.contains(index)"))
        XCTAssertFalse(source.contains("Tell us what this meal swipe is for."))
        let normalizedSource = normalized(source)
        XCTAssertFalse(normalizedSource.contains(normalized("fieldErrorText( .mealDetail")))
        XCTAssertTrue(source.contains("Text(\"Required\")"))
        // The Meal entry's label row, collapsed summary and expanded editor
        // live in the controls shared with Edit; create supplies only its
        // fields, state and provenance.
        XCTAssertTrue(source.contains("struct RequesterMealEntryControl"))
        XCTAssertTrue(source.contains("struct RequesterMealEntryCard"))
        XCTAssertTrue(source.contains("hasError ? Color.red.opacity(0.07)"))
        XCTAssertTrue(source.contains("Text(\"Meal item\")"))
        XCTAssertTrue(source.contains("Text(RequestFoodView.screenshotAssistanceOptionalLabel)"))
        XCTAssertTrue(source.contains("Button(action: onDone)"))
        XCTAssertTrue(normalizedSource.contains(normalized("onDone: { focusedField = nil")))
        XCTAssertTrue(normalizedSource.contains(normalized("expandedMealIndex = nil },")))
        XCTAssertTrue(source.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertTrue(source.contains(".foregroundStyle(Color(\"AccentColor\"))"))
        XCTAssertFalse(source.contains("Button(\"Cancel\")"))
        XCTAssertFalse(source.contains("Text(\"Edited\")"))

        let createStart = try XCTUnwrap(source.range(of: "private func mealEditorCard"))
        let createEnd = try XCTUnwrap(source.range(of: "private var diningDollarsOnlyFields", range: createStart.upperBound..<source.endIndex)
            ?? source.range(of: "/// The Dining-Dollars-only resource fields", range: createStart.upperBound..<source.endIndex))
        let createCard = String(source[createStart.lowerBound..<createEnd.lowerBound])
        XCTAssertTrue(createCard.contains("RequesterMealEntryControl("))
        XCTAssertFalse(createCard.contains(".background("))

        let sharedStart = try XCTUnwrap(source.range(of: "struct RequesterMealEntryControl"))
        let sharedEnd = try XCTUnwrap(source.range(of: "struct RequesterMealSwipesMenu"))
        let shared = String(source[sharedStart.lowerBound..<sharedEnd.lowerBound])
        XCTAssertTrue(shared.contains("VStack(alignment: .leading, spacing: RequestFoodView.mealLabelToControlSpacing)"))
        XCTAssertTrue(shared.contains(".frame(height: RequestFoodView.mealLabelRowHeight)"))
        // W4-R4 (2026-09-27): the 76pt target governs only the EMPTY collapsed
        // control; a FILLED summary is content-driven (44 is only the HIG
        // minimum tap target).
        XCTAssertTrue(shared.contains("isEmptyMealItem ? RequestFoodView.collapsedMealControlHeight : 44"))
        XCTAssertTrue(shared.contains("RequestFoodView.expandedMealControlHeight"))
        XCTAssertEqual(RequestFoodView.mealLabelRowHeight, 18)
        XCTAssertEqual(RequestFoodView.mealLabelToControlSpacing, 7)
        XCTAssertEqual(RequestFoodView.collapsedMealControlHeight, 76)
        XCTAssertEqual(RequestFoodView.expandedMealControlHeight, 158)
        // Each rounded surface belongs to its expanded or collapsed control.
        XCTAssertEqual(shared.components(separatedBy: ".background(").count - 1, 2)
        XCTAssertFalse(shared.contains(".padding(CommonPlateStyle.Spacing.m)"))
    }

    func testPreservedEntryFeedbackIsRerunOnlyAndDoesNotReplacePersistentCheckedState() throws {
        XCTAssertEqual(
            RequestFoodView.preservedEntryFeedbackMessage,
            "Screenshot checked. Your existing entries were kept."
        )
        XCTAssertEqual(RequestFoodView.preservedEntryFeedbackDuration, .seconds(3))

        let preservedManualContent = ScreenshotProposalAppliedFields(
            preservedManualFieldCount: 1
        )
        let noPreservedManualContent = ScreenshotProposalAppliedFields()
        var state = ScreenshotPreservedEntryFeedbackState()

        // First completed Screenshot Assistance run: retained requester
        // content alone is insufficient to present rerun-only feedback.
        state.beginSelection()
        XCTAssertNil(state.completeAnalysis(eligible: true, applying: preservedManualContent))
        XCTAssertFalse(state.isShowing)

        // A later completed selection is a genuine rerun. It shows one
        // bounded acknowledgement only when it actually preserves manual
        // content.
        state.beginSelection()
        let rerunTimeout = state.completeAnalysis(eligible: true, applying: preservedManualContent)
        XCTAssertNotNil(rerunTimeout)
        XCTAssertTrue(state.isShowing)

        state.beginSelection()
        XCTAssertNil(state.completeAnalysis(eligible: true, applying: noPreservedManualContent))
        XCTAssertFalse(state.isShowing)
    }

    func testPreservedEntryFeedbackSelectionGenerationFencesStaleTimeout() {
        let preservedManualContent = ScreenshotProposalAppliedFields(
            preservedManualFieldCount: 1
        )
        var state = ScreenshotPreservedEntryFeedbackState()

        state.beginSelection()
        XCTAssertNil(state.completeAnalysis(eligible: true, applying: preservedManualContent))
        state.beginSelection()
        let staleTimeout = state.completeAnalysis(eligible: true, applying: preservedManualContent)
        XCTAssertTrue(state.isShowing)

        // A third picker selection is a new generation before the old
        // delayed cleanup can fire. Its stale timeout cannot alter this
        // selection's presentation.
        state.beginSelection()
        XCTAssertFalse(state.isShowing)
        state.clearAfterTimeout(ifCurrent: try! XCTUnwrap(staleTimeout))
        XCTAssertFalse(state.isShowing)
    }

    func testRequesterFormUsesCanonicalFixedRhythmAndDirectAccentAssetTint() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        let formStart = try XCTUnwrap(source.range(of: "private var requestForm: some View {"))
        let formEnd = try XCTUnwrap(source.range(of: "// MARK: - W4-R2 approved `Requester / Form Field` controls"))
        let form = String(source[formStart.lowerBound..<formEnd.lowerBound])
        XCTAssertTrue(form.contains("VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m)"))
        // W4-R4: the superseded resting-composition system stays gone. The
        // only `GeometryReader` left measures a height for `Post request`'s
        // placement; it never sizes content or feeds a minHeight/Spacer.
        XCTAssertEqual(form.components(separatedBy: "GeometryReader").count - 1, 1)
        XCTAssertTrue(form.contains("RequesterViewportHeightKey"))
        XCTAssertFalse(form.contains("minHeight: geometry"))
        // The path label now has one bounded spacer for its provenance.
        XCTAssertEqual(form.components(separatedBy: "Spacer(minLength: CommonPlateStyle.Spacing.s)").count - 1, 1)
        XCTAssertFalse(form.contains("Spacer(minLength: geometry"))
        // The Timing row's one `Spacer()` now lives in the header shared with Edit.
        XCTAssertEqual(
            form.components(separatedBy: "Spacer()").count - 1,
            0,
            "no floating keyboard toolbar remains"
        )
        let timingHeader = try XCTUnwrap(source.range(of: "struct RequesterTimingHeader"))
        XCTAssertEqual(String(source[timingHeader.lowerBound...].prefix(1800)).components(separatedBy: "Spacer()").count - 1, 1)
        XCTAssertFalse(form.contains("adaptiveMajorGap"))
        XCTAssertFalse(form.contains("majorGap"))
        XCTAssertTrue(form.contains(".tint(Color(\"AccentColor\"))"))
        XCTAssertTrue(source.contains("private var diningSpotControl"))
        XCTAssertTrue(source.contains("private var mealSwipesControl"))
        XCTAssertTrue(source.contains("private func laterTimeChoices"))

        // The swipe menu's tint now lives in the struct shared with Edit.
        XCTAssertTrue(source.contains("RequesterMealSwipesMenu("))
        for control in ["private var diningSpotControl", "struct RequesterMealSwipesMenu", "private func laterTimeChoices"] {
            let controlStart = try XCTUnwrap(source.range(of: control))
            let controlTail = String(source[controlStart.lowerBound...].prefix(1_500))
            XCTAssertTrue(controlTail.contains(".tint(Color(\"AccentColor\"))"))
        }
    }

    func testRequesterKeyboardDismissalHidesPostingWithoutAFloatingToolbar() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"))
        XCTAssertFalse(source.contains("ToolbarItemGroup(placement: .keyboard)"))
        XCTAssertTrue(source.contains(".background(RequesterOutsideInputDismissal())"))
        XCTAssertTrue(source.contains("if anchorsPostRequest && !isSoftwareKeyboardVisible"))
        XCTAssertTrue(source.contains("if !anchorsPostRequest && !isSoftwareKeyboardVisible"))
        XCTAssertTrue(source.contains("UIResponder.keyboardWillShowNotification"))
        XCTAssertTrue(source.contains("UIResponder.keyboardDidHideNotification"))
        XCTAssertTrue(source.contains("#selector(UIResponder.resignFirstResponder)"))
        XCTAssertTrue(source.contains("focusedField = nil"))
        XCTAssertFalse(source.contains(".accessibilityIdentifier(\"request-keyboard-done\")"))
    }

    /// W4-R2 2026-09-02 sync item 2: the persistent ASAP/Later educational
    /// subtitles are superseded by the on-demand `ⓘ` explanation; the
    /// distinct lapsed-Later-window/unavailability messaging is unaffected.
    func testTimingHasNoPersistentEducationalSubtitles() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var requestForm: some View {"))
        let end = try XCTUnwrap(
            source.range(
                of: "// MARK: - W4-R2 approved `Requester / Form Field` controls",
                range: start.upperBound..<source.endIndex
            )
        )
        let requestFormSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(requestFormSource.contains("Text(Self.asapTimingNotice)"))
        XCTAssertFalse(requestFormSource.contains("request-form-expiration"))
        XCTAssertFalse(requestFormSource.contains("Text(Self.scheduledWindowNotice)"))
        XCTAssertFalse(requestFormSource.contains("scheduled-window-notice"))
        XCTAssertFalse(requestFormSource.contains("Text(\"Selected:"))
        XCTAssertFalse(requestFormSource.contains("request-selected-later-time"))

        // The distinct lapsed-Later-window error/unavailability notice is not
        // an educational subtitle and remains available where required.
        XCTAssertTrue(requestFormSource.contains("Text(Self.scheduledUnavailableNotice)"))
        XCTAssertTrue(requestFormSource.contains("scheduled-unavailable-notice"))
    }

    /// W4-R2 2026-09-02 sync item 4: the quiet on-demand Timing information
    /// affordance — accessible, dismissible, and independent of the current
    /// selection.
    func testTimingInfoAffordancePresentsExactTitleAndBody() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var requestForm: some View {"))
        let end = try XCTUnwrap(
            source.range(
                of: "// MARK: - W4-R2 approved `Requester / Form Field` controls",
                range: start.upperBound..<source.endIndex
            )
        )
        let requestFormSource = String(source[start.lowerBound..<end.lowerBound])

        // The label, info glyph and alert live in the header shared with Edit.
        XCTAssertTrue(requestFormSource.contains("RequesterTimingHeader("))
        XCTAssertTrue(requestFormSource.contains("request-timing-info"))
        let timingHeader = try XCTUnwrap(source.range(of: "struct RequesterTimingHeader"))
        let headerSource = String(source[timingHeader.lowerBound...].prefix(1800))
        XCTAssertTrue(headerSource.contains("isPresentingInfo = true"))
        XCTAssertTrue(headerSource.contains(".alert(RequestFoodView.timingInfoTitle"))
        XCTAssertTrue(headerSource.contains("RequestFoodView.timingInfoBody"))

        XCTAssertEqual(RequestFoodView.timingInfoTitle, "How timing works")
        XCTAssertEqual(
            RequestFoodView.timingInfoBody,
            "ASAP is shown to helpers now.\nLater is shown at your chosen time.\nRequests stay open for up to 3 hours."
        )
    }

    /// W4-R2 2026-09-02 sync item 3: the custom `Choose time` selection
    /// becomes the sole on-screen representation of the effective custom
    /// Later time — no separate `Selected:` sentence.
    func testChooseTimeButtonBecomesTheSelectedCustomTimeLabel() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func laterTimeChoices(quickTimes: [Date]) -> some View {"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func chooseTimeButton(isCustomTimeSelected: Bool) -> some View {",
                range: start.upperBound..<source.endIndex
            )
        )
        let choicesSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(choicesSource.contains("isCustomTimeSelected"))
        XCTAssertTrue(choicesSource.contains("chooseTimeButton(isCustomTimeSelected: isCustomTimeSelected)"))
        XCTAssertFalse(choicesSource.contains("Text(\"Selected:"))
        XCTAssertFalse(choicesSource.contains("request-selected-later-time"))
    }

    func testPostActionUsesOnlySmallPaddingBeyondScrollViewSafeArea() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        // W4-R4: both placements of `Post request` (anchored and in-flow)
        // share this one small value beyond the safe area.
        XCTAssertEqual(RequesterFormLayoutMetrics.contentBottomPadding, CommonPlateStyle.Spacing.xs)
        XCTAssertTrue(source.contains(".padding(.bottom, RequesterFormLayoutMetrics.contentBottomPadding)"))
        XCTAssertFalse(source.contains(".padding(.bottom, CommonPlateStyle.Spacing.l)"))
    }

    /// Extracts the Success presentation's own source text.
    ///
    /// W4-D2 moved that presentation out of `RequestFoodView` and into
    /// `RequestCreationContinuityView`, which is the only place the Success
    /// card, copy, haptic, announcement, and dwell now exist — a pushed
    /// screen structurally cannot reveal Home beneath itself or land into
    /// Home's real slot geometry. These assertions follow the presentation
    /// rather than the former file, and stay bounded to the view's own
    /// `body` (up to its `card(containerWidth:)` helper) so they cannot be
    /// satisfied or defeated by unrelated content elsewhere in the file.
    private func successViewDeclarationSource() throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestCreationContinuityView.swift"
            ),
            encoding: .utf8
        )

        let startMarker = "var body: some View {"
        let endMarker = "private func card(containerSize: CGSize, containerFrame: CGRect) -> some View {"

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after the continuity body")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Extracts one `RequestFoodView` function's own source text, bounded by
    /// `startMarker` and the next `endMarker`, matching
    /// `successViewDeclarationSource()`'s bounded-extraction pattern.
    private func requestFoodViewSource(from startMarker: String, to endMarker: String) throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )
        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after \(startMarker)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// W4-S3 flow ordering: `Choose Grubhub screenshot` / `Change` →
    /// Screenshot Help (if unseen) → picker. There is no third-party-AI
    /// disclosure or consent step before photo selection.
    func testScreenshotAssistanceFlowIsHelpThenPickerWithNoDisclosureOrConsent() throws {
        let source = try requestFoodViewSource(
            from: "private func beginScreenshotAssistanceFlow() {",
            to: "private func proceedToScreenshotSelection() {"
        )

        XCTAssertTrue(source.contains("guard screenshotProposalStore.isAssistanceAvailable,"))
        XCTAssertTrue(source.contains("screenshotProposalStore.isAIAssistanceEnabled, !screenshotProposalStore.isApplying else {"))
        XCTAssertTrue(source.contains("proceedToScreenshotSelection()"))
        XCTAssertFalse(source.lowercased().contains("consent"))
        XCTAssertFalse(source.lowercased().contains("disclosure"))
        XCTAssertFalse(source.contains("isPresentingScreenshotPicker = true"))
        XCTAssertFalse(source.contains("isPresentingScreenshotHelp = true"))
    }

    /// Screenshot Help gates the picker only while Help-completion is
    /// independently false — completion semantics (`Got it`) are unchanged.
    func testProceedToScreenshotSelectionGatesOnIndependentHelpCompletionState() throws {
        let source = try requestFoodViewSource(
            from: "private func proceedToScreenshotSelection() {",
            to: "/// Shared image preparation"
        )

        XCTAssertTrue(source.contains("if screenshotProposalStore.hasCompletedScreenshotHelp {"))
        XCTAssertTrue(source.contains("isPresentingScreenshotPicker = true"))
        XCTAssertTrue(source.contains("isPresentingScreenshotHelp = true"))
    }

    /// W4-S3: the pre-S3 requester-side disclosure and remembered consent
    /// mechanism are gone — superseded by the W4-S3 consent-authority
    /// revision's `Turn on Screenshot Assistance?` disclosure
    /// (`ScreenshotAssistanceDisclosurePresentationTests`), which uses
    /// entirely different identifiers and copy from this retired mechanism.
    func testRequesterViewHasNoPreS3DisclosureOrConsentSurface() throws {
        let view = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let entry = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"),
            encoding: .utf8
        )
        for source in [view, entry] {
            XCTAssertFalse(source.contains("ScreenshotProposalDisclosureView"))
            XCTAssertFalse(source.contains("isPresentingScreenshotDisclosure"))
            XCTAssertFalse(source.contains("recordThirdPartyConsent"))
            XCTAssertFalse(source.contains("hasRecordedThirdPartyConsent"))
            XCTAssertFalse(source.contains("acceptScreenshotDisclosure"))
            XCTAssertFalse(source.contains("cancelScreenshotDisclosure"))
        }
        XCTAssertFalse(view.contains("Use Screenshot Assistance?"))
    }

    /// W4-S3 consent-authority revision: `Turn on Screenshot Assistance`
    /// presents the disclosure rather than flipping the setting directly —
    /// full wiring proof (exact ordering of dismiss/grant/proceed, and the
    /// `Not Now` path) lives in
    /// `ScreenshotAssistanceDisclosurePresentationTests`. This test only
    /// confirms the Off-row action itself does nothing but open that
    /// disclosure.
    func testTurnOnRowOpensTheDisclosureRatherThanEnablingDirectly() throws {
        let source = try requestFoodViewSource(
            from: "private func beginTurnOnScreenshotAssistanceFlow() {",
            to: "private func confirmTurnOnScreenshotAssistance() {"
        )

        XCTAssertTrue(source.contains("isPresentingScreenshotAssistanceDisclosure = true"))
        XCTAssertFalse(source.contains("setAIAssistanceEnabled"))
        XCTAssertFalse(source.contains("proceedToScreenshotSelection()"))
        XCTAssertFalse(source.contains("useExternalAI"))
        XCTAssertFalse(source.contains("isPresentingScreenshotHelp = true"))
        XCTAssertFalse(source.contains("isPresentingScreenshotPicker = true"))
    }

    /// W4-R2 2026-09-01 round-2 sync item 1: Off must show `Screenshot
    /// Assistance` / `Off` / `Turn on Screenshot Assistance` — never the
    /// disabled `Choose Grubhub screenshot` control or the withdrawn
    /// `Screenshot Assistance is off` notice.
    func testOffStateShowsTurnOnAffordanceNotADisabledControl() throws {
        let source = try screenshotAssistanceRowSource()

        XCTAssertTrue(source.contains("if !screenshotProposalStore.isAIAssistanceEnabled {"))
        XCTAssertTrue(source.contains("beginTurnOnScreenshotAssistanceFlow()"))
        XCTAssertTrue(source.contains(RequestFoodView.turnOnScreenshotAssistanceLabel))
        XCTAssertTrue(source.contains(RequestFoodView.screenshotAssistanceOffLabel))
        XCTAssertTrue(source.contains("request-screenshot-turn-on"))
        XCTAssertFalse(source.contains("screenshotOffNotice"))
        XCTAssertFalse(source.contains("Screenshot Assistance is off"))
        XCTAssertFalse(source.contains("request-screenshot-disabled-notice"))
    }

    /// W4-R2 2026-09-02 sync item 1: `Off` is status text only — no
    /// gesture/tap target may be attached to it, and the row/header must not
    /// become tappable. `Turn on Screenshot Assistance` remains the sole
    /// interactive opt-in affordance.
    func testOffLabelIsStaticTextWithNoAttachedInteraction() throws {
        let source = try screenshotAssistanceRowSource()

        let headerStart = try XCTUnwrap(source.range(of: "HStack {"))
        let headerEnd = try XCTUnwrap(
            source.range(
                of: "if !screenshotProposalStore.isAIAssistanceEnabled {",
                range: headerStart.upperBound..<source.endIndex
            )
        )
        let headerSource = String(source[headerStart.lowerBound..<headerEnd.lowerBound])

        // The header HStack renders `Text(Self.screenshotAssistanceTitle)`
        // and the `Optional`/`Off` label as plain `Text`, never a `Button`,
        // `.onTapGesture`, or an added button accessibility trait.
        XCTAssertTrue(headerSource.contains("Self.screenshotAssistanceOffLabel"))
        XCTAssertFalse(headerSource.contains("Button"))
        XCTAssertFalse(headerSource.contains(".onTapGesture"))
        XCTAssertFalse(headerSource.contains(".accessibilityAddTraits(.isButton)"))

        // No tap gesture exists anywhere in the row — the only interactive
        // control across every state is a native `Button`.
        XCTAssertFalse(source.contains(".onTapGesture"))
    }

    /// The Off branch must not also render the ordinary Choose/Change
    /// button or checked-result row underneath it — those remain On-only.
    func testOffStateBranchIsMutuallyExclusiveWithTheOnStateControls() throws {
        let source = try screenshotAssistanceRowSource()

        guard let offRange = source.range(of: "if !screenshotProposalStore.isAIAssistanceEnabled {") else {
            XCTFail("expected to find the Off branch")
            return
        }
        guard let elseRange = source.range(
            of: "} else if screenshotChecked && !screenshotProposalStore.isApplying {",
            range: offRange.upperBound..<source.endIndex
        ) else {
            XCTFail("expected to find the On-state branch immediately following Off")
            return
        }
        let offBranch = String(source[offRange.upperBound..<elseRange.lowerBound])

        XCTAssertFalse(offBranch.contains(RequestFoodView.screenshotChooseLabel))
        XCTAssertFalse(offBranch.contains("request-screenshot-picker"))
        XCTAssertFalse(offBranch.contains("request-screenshot-checked-row"))
    }

    /// W4-R2 2026-09-01 sync item 5: `Got it` — and only `Got it` — records
    /// Screenshot Help completion, immediately followed by opening the photo
    /// picker (the flow this education was blocking).
    func testGotItRecordsHelpCompletionAndOpensThePicker() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        guard let startRange = source.range(of: "ScreenshotHelpView {") else {
            XCTFail("expected to find the ScreenshotHelpView onDismiss closure")
            return
        }
        guard let endRange = source.range(of: "\n                    }", range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find the end of the onDismiss closure")
            return
        }
        let closureBody = String(source[startRange.upperBound..<endRange.lowerBound])

        XCTAssertTrue(closureBody.contains("screenshotProposalStore.recordScreenshotHelpCompleted()"))
        XCTAssertTrue(closureBody.contains("isPresentingScreenshotHelp = false"))
        XCTAssertTrue(closureBody.contains("isPresentingScreenshotPicker = true"))
    }

    /// W4-R2 2026-09-01 sync item 3: both the initial `Choose Grubhub
    /// screenshot` action and the post-analysis `Change` action must run the
    /// same gated flow — neither may open the photo picker directly.
    func testChooseAndChangeBothRunTheGatedFlowNotADirectPicker() throws {
        let source = try screenshotAssistanceRowSource()

        XCTAssertFalse(source.contains("PhotosPicker("))
        let callSites = source.components(separatedBy: "Button {\n").count - 1
        XCTAssertGreaterThanOrEqual(callSites, 2, "expected both Choose and Change to be Button-driven")
        let calls = source.components(separatedBy: "beginScreenshotAssistanceFlow()\n").count - 1
        XCTAssertEqual(calls, 2, "expected exactly the Choose and Change actions to call beginScreenshotAssistanceFlow()")
    }

    /// W4-R2 2026-08-31 sync: item 21's three explanatory second-line
    /// outcomes are withdrawn — no dynamic explanatory copy remains in the
    /// completed-result presentation, only the compact `✓ Screenshot
    /// checked` label and a `Change` action.
    func testScreenshotAssistanceAcknowledgementSecondLineCopyIsWithdrawn() throws {
        let source = try screenshotAssistanceRowSource()

        XCTAssertFalse(source.contains("I found suggestions for a few blank fields."))
        XCTAssertFalse(source.contains("Everything I found was already filled in, so nothing changed."))
        XCTAssertFalse(source.contains("I checked the screenshot, but didn’t find anything new to suggest."))
        XCTAssertTrue(source.contains(RequestFoodView.screenshotCheckedLabel))
        XCTAssertTrue(source.contains(RequestFoodView.screenshotChangeLabel))
    }

    /// Extracts `beginScreenshotAnalysis(...)`'s own source text, matching
    /// `requestFoodViewSource(from:to:)`'s bounded-extraction pattern.
    private func beginScreenshotAnalysisSource() throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        let startMarker = "@MainActor\n    private func beginScreenshotAnalysis("
        let endMarker = "static let afterglowDuration"

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after beginScreenshotAnalysis")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// W4-R2 2026-08-31 sync: derives the compact result row purely from
    /// S1's own already-committed `outcome.eligible` — an ineligible
    /// (unsupported) outcome keeps its existing dedicated notice instead of
    /// showing the checked row, and no new S1 authority/call is introduced
    /// to make the distinction.
    func testScreenshotAcknowledgementIsDerivedOnlyFromExistingS1OutcomeWithoutNewAuthority() throws {
        let source = try beginScreenshotAnalysisSource()
        let storeSource = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift"),
            encoding: .utf8
        )

        // The ONLY write of `screenshotChecked = true` is inside the
        // completion function, behind its own eligibility guard.
        XCTAssertEqual(source.components(separatedBy: "screenshotChecked = true").count - 1, 1)
        let completion = try XCTUnwrap(SwiftSourceFunction.body(
            startingWith: "private func recordCompletedScreenshotAnalysis(eligible: Bool) -> Bool?",
            in: source
        ))
        XCTAssertTrue(completion.contains("screenshotChecked = true"))
        XCTAssertLessThan(
            try XCTUnwrap(completion.range(of: "guard eligible else { return nil }")).lowerBound,
            try XCTUnwrap(completion.range(of: "screenshotChecked = true")).lowerBound,
            "eligibility must be checked before the checked row is established"
        )

        // The application seam never writes it directly; it only reaches the
        // completion function with the outcome's own eligibility, or (for a
        // held A/D result) through the recovery kind, which is nil for any
        // ineligible outcome.
        let applyBody = try XCTUnwrap(SwiftSourceFunction.body(
            startingWith: "private func applyScreenshotOutcome(",
            in: source
        ))
        XCTAssertFalse(applyBody.contains("screenshotChecked"))
        XCTAssertEqual(applyBody.components(separatedBy: "recordCompletedScreenshotAnalysis(").count - 1, 2)
        XCTAssertTrue(applyBody.contains("recordCompletedScreenshotAnalysis(eligible: outcome.eligible)"))
        let recoveryKind = try XCTUnwrap(SwiftSourceFunction.body(
            startingWith: "static func venueRecoveryKind(",
            in: storeSource
        ))
        XCTAssertTrue(
            recoveryKind.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("guard outcome.eligible else { return nil }"),
            "an ineligible outcome must yield no A/D recovery and so never the held-completion call"
        )

        // No second `analyzeScreenshot`/`apply` call and no store-notice
        // mutation: the result row reads S1's existing result through the
        // one application/completion seam; it never asks S1 a new question
        // or writes new S1 state.
        XCTAssertEqual(source.components(separatedBy: "screenshotProposalStore.analyzeScreenshot").count, 2)
        XCTAssertEqual(source.components(separatedBy: "screenshotProposalStore.apply(").count, 2)
        XCTAssertFalse(source.contains("screenshotProposalStore.notice ="))
    }

    /// Extracts `screenshotAssistanceRow`'s own source text, matching the
    /// same bounded-extraction pattern used above.
    private func screenshotAssistanceRowSource() throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        let startMarker = "private var screenshotAssistanceRow: some View {"
        let endMarker = "static let screenshotAssistanceTitle"

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after screenshotAssistanceRow")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// The store's existing `.noUsefulExtraction` notice box would otherwise
    /// duplicate what the compact `✓ Screenshot checked` result row already
    /// communicates; the row must show only the result row for that case,
    /// not both stacked.
    func testNoUsefulExtractionNoticeBoxIsSuppressedInFavorOfTheAcknowledgement() throws {
        let source = try screenshotAssistanceRowSource()

        XCTAssertTrue(source.contains("notice != .noUsefulExtraction"))
        XCTAssertTrue(source.contains("screenshotChecked"))
        XCTAssertTrue(source.contains("Screenshot checked"))
    }

    /// W4-R2 2026-08-31 sync: `Change` is the row's own actionable affordance
    /// for selecting/analyzing another screenshot once one has been checked.
    func testScreenshotCheckedRowOffersAChangeAction() throws {
        let source = try screenshotAssistanceRowSource()

        XCTAssertTrue(source.contains("request-screenshot-checked-row"))
        XCTAssertTrue(source.contains("request-screenshot-change"))
    }

    /// W4-R4: a structured meal's Name and Details are independent current
    /// authority/provenance units; neither helper may inspect or latch the
    /// sibling field.
    func testMealSubfieldBindingsUseIndependentCurrentAuthorityAndProvenance() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        for (binding, call, helperSignature, ownedSet, provenanceSet) in [
            (
                "private func mealItemNameBinding(_ index: Int) -> Binding<String> {",
                "recordManualMealItemNameEdit(index, hasContent: !newValue.isEmpty)",
                "private func recordManualMealItemNameEdit(_ index: Int, hasContent: Bool) {",
                "manuallyEditedMealItemNames",
                "mealItemNames"
            ),
            (
                "private func mealItemDetailsBinding(_ index: Int) -> Binding<String> {",
                "recordManualMealItemDetailsEdit(index, hasContent: !newValue.isEmpty)",
                "private func recordManualMealItemDetailsEdit(_ index: Int, hasContent: Bool) {",
                "manuallyEditedMealItemDetails",
                "mealItemDetails"
            ),
        ] {
            guard let range = source.range(of: binding) else {
                XCTFail("expected to find \(binding)")
                return
            }
            let tail = String(source[range.upperBound...].prefix(420))
            XCTAssertTrue(tail.contains(call))
            XCTAssertFalse(tail.contains("recordManualMealEdit"))

            guard let helperRange = source.range(of: helperSignature) else {
                // The specific source checks below make a missing helper
                // diagnostic straightforward without relying on UI tests.
                XCTFail("expected independent meal-subfield helper")
                return
            }
            let helperTail = String(source[helperRange.upperBound...].prefix(320))
            XCTAssertTrue(helperTail.contains("\(ownedSet).remove(index)"))
            XCTAssertTrue(helperTail.contains("\(ownedSet).insert(index)"))
            XCTAssertTrue(helperTail.contains("screenshotProvenance.\(provenanceSet).remove(index)"))
        }
        XCTAssertFalse(source.contains("manuallyEditedMealEntries"))

        guard let orderDetailsRange = source.range(
            of: "private var orderDetailsBinding: Binding<String> {"
        ) else {
            XCTFail("expected to find orderDetailsBinding")
            return
        }
        let orderDetailsTail = String(source[orderDetailsRange.upperBound...].prefix(300))
        XCTAssertTrue(
            orderDetailsTail.contains("hasManuallyEditedOrderDetails = !newValue.isEmpty"),
            "clearing order details back to \"\" must unlatch manual ownership"
        )

        guard let locationRange = source.range(of: "private var selectedDiningSpotBinding: Binding<DiningSpot?> {") else {
            XCTFail("expected to find selectedDiningSpotBinding")
            return
        }
        let locationTail = String(source[locationRange.upperBound...].prefix(300))
        XCTAssertTrue(
            locationTail.contains("hasManuallyEditedLocation = newValue != nil"),
            "selecting nil (\"Select a spot\") must unlatch, not permanently latch, manual ownership"
        )
    }

    /// W4-R2 2026-08-31 sync "Bottom Continuity": the pushed Request Food
    /// entry plays a brief, bounded settle-in on first appearance, never
    /// gates interactivity on it, and Reduce Motion skips it entirely.
    func testRequestFoodEntrySettleInIsBoundedAndSkipsUnderReduceMotion() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("hasSettled"))
        XCTAssertTrue(source.contains("reduceMotion"))
        XCTAssertTrue(source.contains(".opacity(hasSettled || reduceMotion ? 1 : 0)"))
        // Still the same pushed destination — `.form` continues to return
        // `RequestFoodView(...)` directly, not a new sheet/modal wrapper.
        XCTAssertTrue(source.contains("case .form:"))
    }

    /// W4-R2 2026-09-05 sync item 8: Request Food's own local Bottom
    /// Continuity settle above (never gated on hit testing, per its own
    /// long-standing comment) is now this route's sole entrance cue —
    /// `ContentView`'s shared `SoftFlowEnterDestination` no longer plays its
    /// own duplicate opacity/offset settle or hit-testing gate for
    /// `.requestFood` specifically, while every other route (Settings,
    /// onboarding) keeps that shared wrapper's existing entrance untouched.
    func testRequestFoodIsTheOnlyRouteThatSuppressesTheSharedEntranceWrappersOwnSettle() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/ContentView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("var playsOwnSettle: Bool = true"))
        XCTAssertTrue(source.contains("playsOwnSettle: route != .requestFood"))
        XCTAssertTrue(source.contains(".opacity(playsOwnSettle ? (hasEntered ? 1 : 0) : 1)"))
        XCTAssertTrue(source.contains(".allowsHitTesting(playsOwnSettle ? hasEntered : true)"))
        // W4-O1: the onboarding walkthrough destination is retired; the
        // typed-route destination is now the shared wrapper's only call site.
        XCTAssertFalse(source.contains("shouldAnimate: flowPresentation == .walkthrough"))
    }

    /// W4-R4 (2026-09-26): the segment pill itself carries no animation
    /// modifier, while Later's local insertion uses the restrained
    /// `laterMotionAnimation` set where the selection changes. The old
    /// always-mounted QuietSettle mechanism stays gone.
    func testTimingSegmentIsUnanimatedAndLaterInsertionUsesTheRestrainedLocalMotion() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        guard let controlRange = source.range(of: "private func timingControl(timingOptions: [RequestTiming]) -> some View {") else {
            XCTFail("expected to find timingControl")
            return
        }
        let controlBody = String(source[controlRange.upperBound...].prefix(1_100))
        XCTAssertFalse(
            controlBody.contains(".animation("),
            "the segment pill itself must remain governed by no animation modifier"
        )
        XCTAssertTrue(controlBody.contains("withAnimation(Self.laterMotionAnimation(reduceMotion: reduceMotion))"))

        XCTAssertFalse(source.contains("quietSettleAnimation"))
        XCTAssertFalse(source.contains(".allowsHitTesting(isLaterActive)"))
        XCTAssertFalse(source.contains(".offset(y: isLaterActive"))
    }

    /// W4-R4 (2026-09-26): Later controls are inserted locally (ASAP reserves
    /// no footprint), and `Post request` placement is adaptive without any
    /// spare-height redistribution between sections.
    func testTimingPostRequestUsesLocalInsertionAndMeasuredPlacementWithoutAdaptiveGaps() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let isLaterActive = draft.timing == .later && isScheduledTimingAvailable"))
        XCTAssertTrue(source.contains("if isLaterActive {"))
        XCTAssertTrue(source.contains(".transition(.opacity)"))

        guard let requestFormRange = source.range(of: "private var requestForm: some View {") else {
            XCTFail("expected to find requestForm")
            return
        }
        guard let timingButtonRange = source.range(of: "// MARK: - W4-R2 approved `Requester / Form Field` controls", range: requestFormRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find the end of requestForm")
            return
        }
        let requestFormSource = String(source[requestFormRange.lowerBound..<timingButtonRange.lowerBound])

        XCTAssertTrue(requestFormSource.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(requestFormSource.contains("anchorsPostRequestDecision"))
        XCTAssertFalse(requestFormSource.contains("minHeight: geometry"))
        XCTAssertEqual(requestFormSource.components(separatedBy: "Spacer(minLength: CommonPlateStyle.Spacing.s)").count - 1, 1)
        XCTAssertFalse(requestFormSource.contains("Spacer(minLength: geometry"))
        XCTAssertFalse(requestFormSource.contains("adaptiveMajorGap"))
        XCTAssertFalse(requestFormSource.contains("majorGap"))
    }

    /// W4-R2 final walkthrough sync: Screenshot Help must actually read as
    /// centered against the full device screen, not merely the safe content
    /// area beneath the pushed `Request Food` navigation bar — the dimming
    /// layer and the modal must share one `ignoresSafeArea()` container
    /// rather than the dimming alone ignoring safe areas.
    func testScreenshotHelpOverlayCentersAgainstTheFullScreenNotJustTheSafeContentArea() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        guard let startRange = source.range(of: "if isPresentingScreenshotHelp {") else {
            XCTFail("expected to find the Screenshot Help overlay")
            return
        }
        let overlaySource = String(source[startRange.lowerBound...])
        guard let closingRange = overlaySource.range(of: "\n            }") else {
            XCTFail("expected to find the overlay's closing brace")
            return
        }
        let block = String(overlaySource[overlaySource.startIndex..<closingRange.upperBound])

        XCTAssertTrue(block.contains("ZStack {"))
        XCTAssertTrue(block.contains(".ignoresSafeArea()"))
        // Exactly one `ignoresSafeArea()` covering both the dimming Color and
        // the modal — not a second one scoped only to the dimming layer,
        // which is what previously centered the modal against the narrower
        // safe content area instead of the whole screen.
        XCTAssertEqual(block.components(separatedBy: ".ignoresSafeArea()").count, 2)
    }

    /// W4-R2 final walkthrough sync: Post request must be the shared
    /// restrained rounded-rectangle primary action, not the system
    /// `.borderedProminent` capsule/pill treatment.
    func testPostRequestUsesTheSharedPrimaryActionTreatmentNotTheSystemCapsuleStyle() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        guard let range = source.range(of: "Text(Self.postRequestLabel)") else {
            XCTFail("expected to find the Post request label")
            return
        }
        let tail = String(source[range.upperBound...].prefix(400))

        XCTAssertTrue(tail.contains(".commonPlatePrimaryAction()"))
        XCTAssertFalse(tail.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(tail.contains(".controlSize(.large)"))
    }

    /// A `201` proves the request was persisted, not that anyone will take it.
    @MainActor
    func testExpirationCopyPromisesNoFulfillment() {
        for timing in RequestTiming.allCases {
            let notice = RequestFoodView.formExpirationNotice(for: timing)
            let lowercased = notice.lowercased()
            for forbidden in [
                "will be fulfilled",
                "someone will",
                "a helper will",
                "guarantee"
            ] {
                XCTAssertFalse(
                    lowercased.contains(forbidden),
                    "expiration copy must not promise fulfillment: \(forbidden)"
                )
            }
        }
    }

    /// The old form sentence — "Requests expire after a few hours" — matched
    /// neither backend rule and must not come back in any timing state.
    @MainActor
    func testNoVagueExpirationCopyRemains() {
        for timing in RequestTiming.allCases {
            let notice = RequestFoodView.formExpirationNotice(for: timing)
            let lowercased = notice.lowercased()
            XCTAssertFalse(lowercased.contains("a few hours"))
            XCTAssertFalse(lowercased.contains("automatically"))
        }
    }

    @MainActor
    func testFormExpirationCopyDistinguishesTheTwoBackendRules() {
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .asap).contains("3 hours")
        )
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .later)
                .contains("3 hours after the time you choose")
        )
        XCTAssertNotEqual(
            RequestFoodView.formExpirationNotice(for: .asap),
            RequestFoodView.formExpirationNotice(for: .later)
        )
    }

    // MARK: - Ambiguous-create escape

    /// The POST may already have succeeded, so submission must stay disabled
    /// and the only offered action must be leaving the screen.
    @MainActor
    func testAmbiguousOutcomeKeepsSubmissionDisabledAndOffersOnlyAnExit() {
        XCTAssertFalse(RequestFoodView.allowsSubmission(after: .ambiguous))
        XCTAssertTrue(RequestFoodView.showsReturnHomeAction(for: .ambiguous))
    }

    /// A confirmed backend rejection is recoverable in place: the student can
    /// correct the form and submit again, so it must not be given the exit
    /// action or have submission taken away.
    @MainActor
    func testOrdinaryRejectionsKeepSubmissionAndReceiveNoExitAction() {
        for error: RequestCreatePresentationError in [
            .invalidRequest,
            .requestLimitReached,
            .rateLimited,
            .publicActionsPaused,
            .creationFailed,
            .operationInProgress
        ] {
            XCTAssertTrue(
                RequestFoodView.allowsSubmission(after: error),
                "\(error) must not disable submission"
            )
            XCTAssertFalse(
                RequestFoodView.showsReturnHomeAction(for: error),
                "\(error) must not receive the ambiguous exit action"
            )
        }

        XCTAssertTrue(RequestFoodView.allowsSubmission(after: nil))
        XCTAssertFalse(RequestFoodView.showsReturnHomeAction(for: nil))
    }

    /// The escape must not become a retry. W4-D2 supersedes the former
    /// "Check Active Requests" sentence with the recorded unresolved body.
    @MainActor
    func testAmbiguousCopyNeverInvitesAnotherSubmission() {
        let message = RequestCreatePresentationError.ambiguous.message

        XCTAssertEqual(
            message,
            "\(AppBrand.name) couldn’t confirm whether your request posted."
        )
        XCTAssertFalse(message.lowercased().contains("submit again"))
        XCTAssertFalse(message.lowercased().contains("try again"))
    }

    // MARK: - Derived scheduled window

    @MainActor
    func testScheduledWindowHelperSentenceIsExact() {
        XCTAssertEqual(
            RequestFoodView.scheduledWindowNotice,
            "Helpers will start seeing this request at this time, and for 3 hours after it."
        )
    }

    // MARK: - Late-night scheduling

    @MainActor
    func testLaterRemainsAvailableWhileAFullWindowStillFits() throws {
        for value in [
            "2026-07-28T16:00:00.000Z",
            "2026-07-28T23:29:00.000Z",
            "2026-07-28T23:30:00.000Z"
        ] {
            let now = try date(value)

            XCTAssertTrue(
                RequestFoodView.isScheduledTimingAvailable(
                    now: now,
                    calendar: utcCalendar
                ),
                "a start is still selectable at \(value)"
            )
            XCTAssertEqual(
                RequestFoodView.availableTimingOptions(
                    now: now,
                    calendar: utcCalendar
                ),
                RequestTiming.allCases
            )
        }
    }

    /// Past the latest possible start, no start remains before the
    /// next calendar day, so "Later" — and the date picker it would reveal —
    /// must be withheld rather than shown in an unusable state.
    @MainActor
    func testLaterIsWithheldWhenFewerThanThirtyMinutesRemainToday() throws {
        for value in [
            "2026-07-28T23:31:00.000Z",
            "2026-07-28T23:59:59.000Z"
        ] {
            let now = try date(value)

            XCTAssertFalse(
                RequestFoodView.isScheduledTimingAvailable(
                    now: now,
                    calendar: utcCalendar
                ),
                "no start remains at \(value)"
            )
            XCTAssertEqual(
                RequestFoodView.availableTimingOptions(
                    now: now,
                    calendar: utcCalendar
                ),
                [.asap],
                "ASAP must remain available at \(value)"
            )
        }
    }

    @MainActor
    func testWithheldSchedulingExplainsItselfWithoutOfferingTomorrow() {
        XCTAssertEqual(
            RequestFoodView.scheduledUnavailableNotice,
            "Scheduling is closed for today. ASAP only."
        )
    }

    /// Nothing may schedule into tomorrow: the latest allowed start plus the
    /// derived 30 minutes lands exactly on the day boundary, and a start past
    /// it is rejected even when the picker is somehow still showing.
    @MainActor
    func testNoScheduledWindowCrossesIntoTomorrow() throws {
        let now = try date("2026-07-28T23:31:00.000Z")
        let tomorrowMorning = try date("2026-07-29T09:00:00.000Z")

        XCTAssertFalse(
            RequestFoodView.isValidScheduledWindow(
                startingAt: tomorrowMorning,
                now: now,
                calendar: utcCalendar
            )
        )
        // At this `now` scheduling has already closed for the day, so the
        // refusal is the lapsed one — there is no pickup time left to offer.
        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                draft: RequestFoodFormDraft(
                    selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                    menuPath: .mealExchange,
                    timing: .later,
                    preferredPickupTime: tomorrowMorning,
                    mealSwipes: 2,
                    mealEntries: ["Chicken bowl"] + Array(repeating: "filler", count: 2 - 1) + Array(repeating: "", count: RequestFoodFormDraft.maxMealSwipes - 2)
                ),
                now: now,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .scheduledTimingUnavailable)
        }

        // The boundary rule itself is unchanged: while scheduling is still open,
        // a start that lands in tomorrow is refused as a correctable start.
        let openNow = try date("2026-07-28T16:00:00.000Z")
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: openNow,
            calendar: utcCalendar
        ))
        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                draft: RequestFoodFormDraft(
                    selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                    menuPath: .mealExchange,
                    timing: .later,
                    preferredPickupTime: tomorrowMorning,
                    mealSwipes: 2,
                    mealEntries: ["Chicken bowl"] + Array(repeating: "filler", count: 2 - 1) + Array(repeating: "", count: RequestFoodFormDraft.maxMealSwipes - 2)
                ),
                now: openNow,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .invalidScheduledTime)
        }
    }

    // MARK: - W4-R2 2026-08-31 round-2 sync: Posting/Success Back suppression

    @MainActor
    func testBackNavigationIsSuppressedOnlyForPostingAndSuccess() {
        XCTAssertTrue(RequestFoodView.shouldSuppressBackNavigation(presentation: .posting))
        XCTAssertTrue(RequestFoodView.shouldSuppressBackNavigation(presentation: .success))

        XCTAssertFalse(RequestFoodView.shouldSuppressBackNavigation(presentation: .form))
        XCTAssertFalse(
            RequestFoodView.shouldSuppressBackNavigation(presentation: .blockedByUnresolvedCreateAmbiguity)
        )
        XCTAssertFalse(
            RequestFoodView.shouldSuppressBackNavigation(presentation: .checkingCreateAmbiguity)
        )
        XCTAssertFalse(
            RequestFoodView.shouldSuppressBackNavigation(presentation: .checkingAvailability)
        )
        XCTAssertFalse(
            RequestFoodView.shouldSuppressBackNavigation(
                presentation: .unavailable(message: "x", retryable: true)
            )
        )
    }

    // MARK: - Availability gating

    @MainActor
    func testAvailablePostingShowsTheForm() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: false,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false
            ),
            .form
        )
    }

    @MainActor
    func testPausedPostingHidesTheFormAndShowsTheLockedSentence() {
        let presentation = RequestFoodView.presentation(
            hasUnresolvedCreateAmbiguity: false,
            availability: .paused,
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: "Posting a meal request is temporarily unavailable.",
                retryable: false
            )
        )
        XCTAssertNotEqual(presentation, .form)
    }

    /// Fail-closed: a probe that could not be completed or decoded must not
    /// reveal the fields, and must not claim posting is paused when the app
    /// only failed to find out.
    @MainActor
    func testFailedAvailabilityCheckHidesTheFormWithoutClaimingItIsPaused() {
        let presentation = RequestFoodView.presentation(
            hasUnresolvedCreateAmbiguity: false,
            availability: .unavailable,
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation, .form)
        XCTAssertNotEqual(RequestFoodView.availabilityUnknownNotice, RequestFoodView.pauseNotice)
    }

    /// No form may render while the answer is pending, so the private fields
    /// cannot flash into view before availability is known.
    @MainActor
    func testUnknownAvailabilityShowsNeitherFormNorAnUnavailableClaim() {
        for hasAttempted in [true, false] {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    hasUnresolvedCreateAmbiguity: false,
                    availability: .unknown,
                    isCheckingAvailability: true,
                    hasAttemptedAvailabilityCheck: hasAttempted,
                    didCreateRequest: false
                ),
                .checkingAvailability
            )
        }
    }

    /// Before the screen's own task has started anything there is nothing to
    /// retry, so the pending state is correct — and still withholds the form.
    @MainActor
    func testUnknownAvailabilityBeforeAnyProbeStaysPendingWithoutOfferingRetry() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: false,
                availability: .unknown,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: false,
                didCreateRequest: false
            ),
            .checkingAvailability
        )
    }

    /// The defect this rule exists for: a probe that ended without an answer.
    /// `.unknown` with nothing running is a finished attempt, not a pending
    /// one, and must never render as an indefinite spinner.
    @MainActor
    func testSettledUnknownAvailabilityOffersRetryInsteadOfAnIndefiniteSpinner() {
        let presentation = RequestFoodView.presentation(
            hasUnresolvedCreateAmbiguity: false,
            availability: .unknown,
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation, .checkingAvailability)
        XCTAssertNotEqual(presentation, .form)
        // It says CommonPlate could not find out — not that posting is off, not
        // that the network is at fault, and not that anything is retrying.
        XCTAssertEqual(
            RequestFoodView.availabilityUnknownNotice,
            "We couldn’t check whether posting is available right now. Please try again in a moment."
        )
        XCTAssertNotEqual(RequestFoodView.availabilityUnknownNotice, RequestFoodView.pauseNotice)
    }

    /// W4-D2 Success→Home continuity gating (required proof): an unresolved
    /// D1 ambiguity outranks `didCreateRequest` — this exact process never
    /// entered the Success→Home continuity screen for *this* operation
    /// (production never sets both simultaneously; `didCreateRequest` only
    /// becomes true once the store has confirmed CREATED, which retires the
    /// ambiguity block), but the presentation function's own precedence must
    /// still fail closed if it ever did.
    @MainActor
    func testUnresolvedAmbiguityOutranksConfirmedCreateForSuccessGating() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: true,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: true
            ),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertNotEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: true,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: true
            ),
            .success
        )
    }

    /// A confirmed create keeps its success screen regardless of what the
    /// availability probe last reported.
    @MainActor
    func testConfirmedCreateShowsSuccessInEveryAvailabilityState() {
        for availability in [
            RequestCreationAvailability.unknown,
            .available,
            .paused,
            .unavailable
        ] {
            for isChecking in [true, false] {
                XCTAssertEqual(
                    RequestFoodView.presentation(
                        hasUnresolvedCreateAmbiguity: false,
                        availability: availability,
                        isCheckingAvailability: isChecking,
                        hasAttemptedAvailabilityCheck: true,
                        didCreateRequest: true
                    ),
                    .success
                )
            }
        }
    }

    // MARK: - W4-R2 Posting / D1 checking states

    /// An ordinary in-flight submission replaces the form with the centered
    /// Posting state, regardless of what the availability probe last
    /// reported — the same "outranks availability presentation" shape
    /// `didCreateRequest` already has above.
    @MainActor
    func testInFlightCreateShowsPostingRegardlessOfAvailability() {
        for availability in [
            RequestCreationAvailability.unknown,
            .available,
            .paused,
            .unavailable
        ] {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    hasUnresolvedCreateAmbiguity: false,
                    availability: availability,
                    isCheckingAvailability: false,
                    hasAttemptedAvailabilityCheck: true,
                    didCreateRequest: false,
                    isCreating: true
                ),
                .posting
            )
        }
    }

    /// A confirmed creation always outranks a merely in-flight one: once
    /// `didCreateRequest` is true, `.success` wins even if `isCreating` is
    /// still momentarily true in the same state snapshot.
    @MainActor
    func testConfirmedCreateOutranksInFlightPosting() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: false,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: true,
                isCreating: true
            ),
            .success
        )
    }

    /// D1 reconciliation actively running reads as "Checking your request",
    /// distinct from the already-resolved-unresolved blocked state.
    @MainActor
    func testUnresolvedAmbiguityWhileCreatingShowsCheckingNotBlocked() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: true,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false,
                isCreating: true
            ),
            .checkingCreateAmbiguity
        )
    }

    /// Once reconciliation stops without resolving, the same unresolved
    /// ambiguity reads as the static blocked state instead.
    @MainActor
    func testUnresolvedAmbiguityNotCreatingShowsBlocked() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: true,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false,
                isCreating: false
            ),
            .blockedByUnresolvedCreateAmbiguity
        )
    }

    /// Every existing call site that never passes `isCreating` must keep
    /// reproducing exactly the presentation it always has — the default
    /// parameter must not silently change any pre-existing caller's result.
    @MainActor
    func testOmittingIsCreatingDefaultsToPreR2Behavior() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: false,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false
            ),
            .form
        )
    }

    // MARK: - W4-R2 definitive-failure summary

    @MainActor
    func testDraftSummaryRestatesOnlyAlreadyEnteredValues() throws {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .asap,
            mealSwipes: 2
        )
        let summary = RequestFoodView.draftSummaryText(for: draft)

        XCTAssertTrue(summary.contains("Jasper Kane Cafe"))
        XCTAssertTrue(summary.contains("2 meal swipes"))
        XCTAssertTrue(summary.contains("ASAP"))
    }

    // MARK: - W4-R2 D1/ambiguous exit copy

    @MainActor
    func testGoToHomeIsTheExactAmbiguousExitLabel() {
        XCTAssertEqual(RequestFoodView.goToHomeLabel, "Go to Home")
    }

    // MARK: - Availability probe state machine

    /// Entry probes once, and the screen shows the checking state only while
    /// that probe is genuinely running.
    func testEntryStartsOneProbeAndShowsCheckingOnlyWhileItRuns() async {
        let store = makeAvailabilityStore()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false),
            gate: gate
        ))

        let probe = Task { await store.refreshRequestCreationAvailability() }
        await waitUntil { gate.isWaiting }

        XCTAssertTrue(store.isCheckingRequestCreationAvailability)
        XCTAssertTrue(store.hasAttemptedRequestCreationAvailabilityCheck)
        XCTAssertEqual(store.requestCreationAvailability, .unknown)
        XCTAssertEqual(presentation(for: store), .checkingAvailability)

        gate.open()
        await probe.value

        XCTAssertFalse(store.isCheckingRequestCreationAvailability)
        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(presentation(for: store), .form)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
    }

    /// The exact race: a probe is cancelled by a screen exit, a re-entry's call
    /// is dropped because the first is still marked in flight, and the first
    /// then resolves back to `.unknown`. That used to strand the screen on a
    /// spinner with nothing running behind it.
    func testCancelledProbeAndReentryCannotStrandAnIndefiniteSpinner() async {
        let store = makeAvailabilityStore()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false),
            gate: gate
        ))

        let probe = Task { await store.refreshRequestCreationAvailability() }
        await waitUntil { gate.isWaiting }

        probe.cancel()
        // The re-entering screen's task, arriving before the cancelled probe
        // has settled: it must not open a second connection.
        await store.refreshRequestCreationAvailability()
        gate.open()
        await probe.value

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"],
            "A dropped concurrent call must not duplicate the network request"
        )
        // Cancellation is not a backend verdict, so the state stays `.unknown`…
        XCTAssertEqual(store.requestCreationAvailability, .unknown)
        XCTAssertNotEqual(store.requestCreationAvailability, .unavailable)
        // …but nothing is running, and the attempt is on record, so the screen
        // settles into a retryable state instead of a permanent spinner.
        XCTAssertFalse(store.isCheckingRequestCreationAvailability)
        XCTAssertTrue(store.hasAttemptedRequestCreationAvailabilityCheck)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation(for: store), .checkingAvailability)
        XCTAssertNotEqual(presentation(for: store), .form)
    }

    /// Retry is the only recovery, and it has to actually probe again.
    func testRetryAfterAnUnresolvedProbeStartsANewProbeAndCanRevealTheForm() async {
        let store = makeAvailabilityStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .unavailable)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )

        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: false)))
        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(presentation(for: store), .form)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions", "/api/public-actions"]
        )
    }

    /// Structured refusals and transport loss both land on the same truthful
    /// retryable state, and neither is ever mistaken for a confirmed pause.
    func testStructuredAndTransportFailuresBothReachTheRetryableState() async {
        let failures: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("transport", .failure(.notConnectedToInternet)),
            ("structured", .response(
                statusCode: 500,
                data: Data(#"{"error":{"code":"INTERNAL_FAILURE","message":"boom"}}"#.utf8)
            ))
        ]

        for (label, stub) in failures {
            RequestFetchingURLProtocol.reset()
            let store = makeAvailabilityStore()
            RequestFetchingURLProtocol.enqueue(stub)

            await store.refreshRequestCreationAvailability()

            XCTAssertEqual(store.requestCreationAvailability, .unavailable, label)
            XCTAssertFalse(store.isCheckingRequestCreationAvailability, label)
            XCTAssertEqual(
                presentation(for: store),
                .unavailable(
                    message: RequestFoodView.availabilityUnknownNotice,
                    retryable: true
                ),
                label
            )
            XCTAssertNotEqual(presentation(for: store), .form, label)
        }
    }

    /// A confirmed pause is unchanged: locked sentence, no retry, no fields.
    func testConfirmedPauseKeepsItsExistingUnavailableBehavior() async {
        let store = makeAvailabilityStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: true)))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .paused)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(message: RequestFoodView.pauseNotice, retryable: false)
        )
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request")
        )
    }

    /// Whatever the availability path does, it may never reveal the fields on
    /// anything but a confirmed available answer.
    func testFormIsWithheldUntilAvailabilityIsAffirmativelyConfirmed() async {
        let stubs: [RequestFetchingURLProtocol.Stub] = [
            .response(data: publicActionsResponse(paused: true)),
            .failure(.notConnectedToInternet),
            .response(data: Data(#"{"paused":"maybe"}"#.utf8))
        ]

        for stub in stubs {
            RequestFetchingURLProtocol.reset()
            let store = makeAvailabilityStore()
            RequestFetchingURLProtocol.enqueue(stub)

            await store.refreshRequestCreationAvailability()

            XCTAssertNotEqual(presentation(for: store), .form)
        }
    }

    // MARK: - Process-lifetime ambiguous-create lock

    /// The lock exists because `POST /api/request` is not idempotent and
    /// carries no operation identity: once iOS cannot read the outcome, it can
    /// never learn whether the record exists, so no further create is safe.
    @MainActor
    func testIndeterminateCreateArmsTheProcessLifetimeGuard() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()

        await assertCreateThrowsAmbiguity(store)

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNotNil(store.unresolvedCreateError)
    }

    /// The defect this closes: `submissionError` is `@State`, so a form rebuilt
    /// after the ambiguous create came back with a nil error, a live Submit
    /// button, and no warning — even though the store would refuse the tap.
    @MainActor
    func testReopeningTheFormRestoresTheBlockingAmbiguityPresentation() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        // A brand-new view instance: no local error survived the teardown.
        let rebuiltViewError = RequestFoodView.effectiveSubmissionError(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            submissionError: nil
        )

        XCTAssertEqual(rebuiltViewError, .ambiguous)

        let presentation = try XCTUnwrap(
            RequestFoodView.submissionSectionPresentation(for: rebuiltViewError)
        )
        XCTAssertEqual(presentation.error, .ambiguous)
        XCTAssertEqual(
            presentation.message,
            "\(AppBrand.name) couldn’t confirm whether your request posted."
        )
        // The only offered move is leaving, never a retry.
        XCTAssertTrue(presentation.showsReturnHomeAction)
    }

    @MainActor
    func testSubmitStaysDisabledForACompleteDraftWhileTheGuardExists() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        let completeDraft = try completeRequestDraft()
        // Without the guard this draft is submittable, so the assertion below
        // is about the guard rather than about missing input.
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: completeDraft,
            submissionError: nil,
            isCreating: false
        ))

        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: completeDraft,
            submissionError: RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            isCreating: false
        ))
    }

    /// The guard is a real refusal, not only a disabled button: even a caller
    /// that reaches the store directly sends nothing.
    @MainActor
    func testGuardedCreateSendsNoSecondPOST() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"]
        )

        // A stub that would confirm a create if the guard ever let one through.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "second"))
        ))

        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"],
            "A guarded create must not reach the network at all"
        )
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// Editing the draft or rebuilding the screen are ordinary local actions.
    /// Neither can resolve a question only the backend could answer.
    @MainActor
    func testDraftEditsAndViewRecreationDoNotClearTheGuard() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        var editedDraft = try completeRequestDraft()
        editedDraft.mealEntries[0] = "A completely different meal"
        editedDraft.diningDollarsText = "9.99"

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(
            RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            .ambiguous,
            "The guard is not scoped to the payload that raised it"
        )
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: editedDraft,
            submissionError: RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            isCreating: false
        ))
    }

    /// Deliberate limitation, recorded so it cannot be mistaken for a fix: the
    /// guard lives in this store only. A relaunch loses it. Durable
    /// reconciliation is Week 3 work and is a release blocker before external
    /// testing.
    @MainActor
    func testGuardIsProcessLocalAndIsNotPersisted() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertFalse(
            makeStore().hasUnresolvedCreateAmbiguity,
            "Nothing persists the guard; a fresh store starts unguarded"
        )
    }

    // MARK: - Ambiguity outranks availability

    /// Every availability answer is a smaller fact than "your request may
    /// already exist". None of them changes what this student can do next, so
    /// none of them may take the screen.
    @MainActor
    func testBlockedPresentationWinsOverEveryAvailabilityState() {
        let availabilityStates: [(String, RequestCreationAvailability, Bool, Bool)] = [
            // label, availability, isChecking, hasAttempted
            ("unknown before any probe", .unknown, false, false),
            ("probe in flight", .unknown, true, true),
            ("settled unknown", .unknown, false, true),
            ("confirmed unavailable", .unavailable, false, true),
            ("paused", .paused, false, true),
            ("available", .available, false, true)
        ]

        for (label, availability, isChecking, hasAttempted) in availabilityStates {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    hasUnresolvedCreateAmbiguity: true,
                    availability: availability,
                    isCheckingAvailability: isChecking,
                    hasAttemptedAvailabilityCheck: hasAttempted,
                    didCreateRequest: false
                ),
                .blockedByUnresolvedCreateAmbiguity,
                "\(label) must not replace the ambiguity warning"
            )
        }
    }

    /// The blocked screen is not the form with a message on it. There is
    /// nothing to correct and nothing to resend, so no field or submit control
    /// may exist to suggest otherwise.
    @MainActor
    func testBlockedStateNeverExposesTheRequestForm() async {
        let store = makeStore()

        // Reach the one availability answer that normally reveals the form,
        // through the real probe, *before* arming the guard — so the block is
        // demonstrably overriding `.available` rather than an absent answer.
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false)
        ))
        await store.refreshRequestCreationAvailability()
        XCTAssertEqual(presentation(for: store), .form)

        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(
            presentation(for: store),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertNotEqual(presentation(for: store), .form)
    }

    /// The blocked screen takes its words and its one action from the same seam
    /// the in-form error row uses, so a change to either cannot leave them
    /// describing one situation two ways.
    @MainActor
    func testBlockedPresentationReusesTheOriginalAmbiguityCopyAndAction() throws {
        let presentation = try XCTUnwrap(
            RequestFoodView.submissionSectionPresentation(for: .ambiguous)
        )

        XCTAssertEqual(presentation.error, .ambiguous)
        XCTAssertEqual(
            presentation.message,
            "\(AppBrand.name) couldn’t confirm whether your request posted."
        )
        XCTAssertTrue(presentation.showsReturnHomeAction)
    }

    /// Re-entry must not spend a request on an answer the screen cannot use.
    /// This drives the production `.task` decision rather than restating it.
    @MainActor
    func testBlockedReentryStartsNoAvailabilityProbe() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertFalse(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ))

        // The body of the screen's `.task`, run exactly as production does.
        if RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ) {
            await store.refreshRequestCreationAvailability()
        }

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"],
            "A blocked screen must not probe availability"
        )
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths
                .contains("/api/public-actions")
        )
    }

    /// The block is the only thing suppressed here. A store that never saw an
    /// ambiguous create keeps the whole normal availability flow, probe
    /// included.
    @MainActor
    func testUnguardedStoreKeepsTheNormalAvailabilityFlow() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false)
        ))

        XCTAssertTrue(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ))

        if RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ) {
            await store.refreshRequestCreationAvailability()
        }

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
        XCTAssertEqual(presentation(for: store), .form)
    }

    /// Blocked means blocked: no create POST escapes through the new screen.
    @MainActor
    func testBlockedScreenSendsNoSecondCreatePOST() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "escaped"))
        ))
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"]
        )
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// Still deliberately not durable. A destroyed store starts clean and runs
    /// the ordinary availability flow — see the Week 3 reconciliation deferral.
    @MainActor
    func testDestroyingTheStoreLosesTheBlockWithoutPersistence() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)
        XCTAssertEqual(presentation(for: store), .blockedByUnresolvedCreateAmbiguity)

        let replacement = makeStore()

        XCTAssertFalse(replacement.hasUnresolvedCreateAmbiguity)
        XCTAssertNotEqual(
            presentation(for: replacement),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertTrue(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: replacement.hasUnresolvedCreateAmbiguity
        ))
    }

    // MARK: - Definitive create refusals never arm the guard

    /// The throttle refuses ahead of validation, the write, and every side
    /// effect, so it proves nothing was created. Reporting it as ambiguous
    /// would turn a sixth tap inside one minute into a permanent lockout.
    @MainActor
    func testRateLimitedCreateIsDefinitiveAndLeavesTheGuardUnset() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"""
            {"error":{"code":"RATE_LIMITED","message":"Too many attempts. Please wait a moment and try again.","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A throttled create must be refused")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "RATE_LIMITED")
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.unresolvedCreateError)

        let presented = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "RATE_LIMITED", message: "Too many attempts.")
        )
        XCTAssertEqual(presented, .rateLimited)
        XCTAssertEqual(
            presented.message,
            "Too many attempts. Please wait a moment and try again."
        )
        // Recoverable in place: the student waits and submits the same request.
        XCTAssertTrue(RequestFoodView.allowsSubmission(after: presented))
        XCTAssertFalse(RequestFoodView.showsReturnHomeAction(for: presented))
    }

    // MARK: - Independent-review fix: write-uncertain REQUEST_CREATION_FAILED
    // must not fire the definitive-failure haptic

    /// The exact integrated path the review flagged: `createRequestRoute.ts`
    /// can return `REQUEST_CREATION_FAILED` from a path that follows a write
    /// attempt, so `RequestStore.createRequest` (unlike the rate-limit case
    /// above) authoritatively arms `hasUnresolvedCreateAmbiguity` for it —
    /// while the view's own local `RequestCreatePresentationError.map`
    /// resolves the identical code to `.creationFailed`, a case that reads as
    /// definitive on its own. Proven end to end through the real store
    /// against a stubbed backend response, then through the real mapping and
    /// the real haptic-gating predicate, so nothing here hand-waves the
    /// store's actual D1 state.
    @MainActor
    func testWriteUncertainCreationFailedArmsAmbiguityAndSuppressesTheFailureHaptic() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: Data(#"""
            {"error":{"code":"REQUEST_CREATION_FAILED","message":"Unable to create request","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A write-uncertain create must still be thrown to the caller")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "REQUEST_CREATION_FAILED")
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        // The store's own authority: unresolved, exactly like an ambiguous
        // transport outcome — never retired as a definitive non-create.
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNotNil(store.unresolvedCreateError)

        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "REQUEST_CREATION_FAILED", message: "Unable to create request")
        )
        XCTAssertEqual(mapped, .creationFailed, "the local mapping alone still reads as definitive")

        // The bug: deciding the haptic from `mapped` alone would fire it here.
        // The fix: the store's real, current `hasUnresolvedCreateAmbiguity`
        // overrides that local reading.
        XCTAssertFalse(
            RequestFoodView.isDefinitiveNonCreate(
                mapped: mapped,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            ),
            "an unresolved write must never be treated as a definitive non-create"
        )
    }

    /// A genuinely definitive non-create (no store ambiguity armed) must
    /// still receive the accepted failure haptic/presentation — the fix must
    /// not silence real failures along with the write-uncertain one above.
    @MainActor
    func testGenuinelyDefinitiveFailureStillQualifiesForTheFailureHaptic() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 400,
            data: Data(#"""
            {"error":{"code":"INVALID_REQUEST","message":"backend detail","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("An invalid request must be refused")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "INVALID_REQUEST")
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "INVALID_REQUEST", message: "backend detail")
        )
        XCTAssertEqual(mapped, .invalidRequest)
        XCTAssertTrue(
            RequestFoodView.isDefinitiveNonCreate(
                mapped: mapped,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            ),
            "a genuine definitive non-create must still receive the failure haptic/presentation"
        )
    }

    /// W4-R2 2026-09-05 sync item 6: drives the real caught error through the
    /// exact production-owned function `RequestFoodView.submit()`'s real
    /// catch path calls — `submissionFailureOutcome(for:hasUnresolvedCreateAmbiguity:)`
    /// — rather than independently reconstructing the same map/gate decision
    /// by hand, so this is provably exercising what `submit()` itself does,
    /// not a second parallel decision that could silently drift from it.
    @MainActor
    func testRealAmbiguousCreationFailedOutcomeThroughTheProductionFunctionSuppressesTheHaptic() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: Data(#"""
            {"error":{"code":"REQUEST_CREATION_FAILED","message":"Unable to create request","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A write-uncertain create must still be thrown to the caller")
        } catch {
            let outcome = RequestFoodView.submissionFailureOutcome(
                for: error,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            )
            XCTAssertEqual(outcome.mapped, .creationFailed, "the local mapping alone still reads as definitive")
            XCTAssertFalse(
                outcome.isDefinitiveFailure,
                "an unresolved write must never be treated as a definitive non-create"
            )
        }
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
    }

    /// The definitive-failure counterpart, through the same production
    /// function: a genuine `INVALID_REQUEST` refusal must still fire the
    /// accepted failure haptic/presentation.
    @MainActor
    func testRealDefinitiveInvalidRequestOutcomeThroughTheProductionFunctionFiresTheFailureHaptic() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 400,
            data: Data(#"""
            {"error":{"code":"INVALID_REQUEST","message":"backend detail","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("An invalid request must be refused")
        } catch {
            let outcome = RequestFoodView.submissionFailureOutcome(
                for: error,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            )
            XCTAssertEqual(outcome.mapped, .invalidRequest)
            XCTAssertTrue(
                outcome.isDefinitiveFailure,
                "a genuine definitive non-create must still receive the failure haptic/presentation"
            )
        }
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    /// A real ambiguous transport outcome (the pre-existing `.ambiguous`
    /// case) must also remain excluded from the failure haptic, regardless of
    /// the new store-authority check — the fix adds a second, wider gate; it
    /// does not narrow the original one.
    @MainActor
    func testAmbiguousTransportOutcomeStillSuppressesTheFailureHaptic() {
        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.ambiguousCreateOutcome(underlying: URLError(.timedOut))
        )
        XCTAssertEqual(mapped, .ambiguous)
        XCTAssertFalse(
            RequestFoodView.isDefinitiveNonCreate(mapped: mapped, hasUnresolvedCreateAmbiguity: true)
        )
        // Even if the store's ambiguity flag were somehow already clear by
        // the time this renders, `.ambiguous` itself must still suppress it.
        XCTAssertFalse(
            RequestFoodView.isDefinitiveNonCreate(mapped: mapped, hasUnresolvedCreateAmbiguity: false)
        )
    }

    /// A bare 404 means this route does not exist at this base URL — a
    /// misconfigured host or an unmounted route. Nothing was created, so it must
    /// not claim the request may already exist.
    @MainActor
    func testBareNotFoundIsDefinitiveAndPermitsAnotherAttempt() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data("<html>Cannot POST /api/request</html>".utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A 404 create must be refused")
        } catch RequestServiceError.notFound {
            // Expected.
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.unresolvedCreateError)

        let presented = RequestCreatePresentationError.map(RequestServiceError.notFound)
        XCTAssertNotEqual(presented, .ambiguous)
        XCTAssertTrue(RequestFoodView.allowsSubmission(after: presented))

        // Unblocked: the next attempt genuinely reaches the network, and this
        // one is confirmed rather than retried automatically.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "after-404"))
        ))
        try? await store.createRequest(makeCreatePayload())

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request", "/api/request"]
        )
        // W4-D2 Success→Home continuity: a fresh create under the still-
        // current authority now inserts immediately, ownership-resolved
        // `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["after-404"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    // MARK: - Genuine indeterminacy stays ambiguous

    /// Being an error is not proof of a rollback. Each of these leaves the
    /// backend's write status genuinely unknown, so each arms the guard — and
    /// each sends exactly one POST.
    @MainActor
    func testIndeterminateFailuresStayAmbiguousWithExactlyOnePOST() async {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("timeout", .failure(.timedOut)),
            ("transport loss", .failure(.networkConnectionLost)),
            (
                "undecodable 5xx",
                .response(statusCode: 502, data: Data("Bad Gateway".utf8))
            ),
            (
                "undecodable success body",
                .response(statusCode: 201, data: Data("{".utf8))
            )
        ]

        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let store = makeStore()
            RequestFetchingURLProtocol.enqueue(stub)

            do {
                try await store.createRequest(makeCreatePayload())
                XCTFail("\(label) cannot confirm creation")
            } catch RequestServiceError.ambiguousCreateOutcome {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(label): \(error)")
            }

            XCTAssertTrue(
                store.hasUnresolvedCreateAmbiguity,
                "\(label) must arm the process-lifetime guard"
            )
            XCTAssertEqual(
                RequestFetchingURLProtocol.capturedRequestedPaths,
                ["/api/request"],
                "\(label) must send exactly one POST and never retry"
            )
            XCTAssertTrue(store.requests.isEmpty)
        }
    }

    // MARK: - ASAP wording

    /// Under the revised W3-R1 presentation contract the backend's concise
    /// `"ASAP"` label carries no duration of its own — the three-hour rule is
    /// explained once, at the timing choice, not restated on every surface
    /// that renders the label. This proves iOS preserves whatever backend
    /// value it is given verbatim, and that the superseded phrasings — "within
    /// the next hour" and "within the next 5 hours" — do not reappear.
    @MainActor
    func testASAPWindowTextPreservesTheBackendProvidedLabel() async throws {
        let asapWindowText = "ASAP"

        let request = try await decodedCreatedRequest(
            createResponse(requestObject: createdRequestObject(
                id: "asap",
                pickupWindowText: asapWindowText
            ))
        )
        XCTAssertEqual(request.pickupWindowText, asapWindowText)
        XCTAssertFalse(request.pickupWindowText.contains("within the next hour"))
        XCTAssertFalse(request.pickupWindowText.contains("within the next 5 hours"))

        // The timing-choice form still explains the same three-hour rule the
        // backend enforces; the helper-facing label itself no longer needs to
        // restate it.
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .asap).contains("3 hours")
        )
    }

    // MARK: - Ambiguity helpers

    private func enqueueIndeterminateCreateFailure() {
        RequestFetchingURLProtocol.enqueue(.failure(.timedOut))
    }

    @MainActor
    private func assertCreateThrowsAmbiguity(
        _ store: RequestStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("Expected an ambiguous create refusal", file: file, line: line)
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected create error: \(error)", file: file, line: line)
        }
    }

    private func completeRequestDraft() throws -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
    }

    private func makeCreatePayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Chicken bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func createResponse(requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func createdRequestObject(
        id: String,
        pickupWindowText: String = "ASAP"
    ) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Jasper Kane Cafe",
          "food": "Chicken bowl",
          "pickupWindowText": "\(pickupWindowText)",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }
        """
    }

    /// W4-R2 2026-09-05 sync item 5: `RequestStore.createRequest` no longer
    /// inserts into `store.requests` (H4's own authoritative fetch owns
    /// that), so decoded-shape assertions call the same production
    /// `RequestService.createRequest` the store itself calls, directly — it
    /// already returns the decoded `FoodRequest`, matching
    /// `RequestFetchingTests.testCreateDecodesWrappedCanonicalResponseAndMapsOpenStatus`'s
    /// own pattern.
    @MainActor
    private func decodedCreatedRequest(_ data: Data) async throws -> FoodRequest {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        let service = RequestService(client: client)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: data))
        return try await service.createRequest(makeCreatePayload())
    }

    /// Mirrors the production call exactly, guard included, so the availability
    /// tests exercise the same precedence the screen applies.
    private func presentation(for store: RequestStore) -> RequestFormPresentation {
        RequestFoodView.presentation(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            availability: store.requestCreationAvailability,
            isCheckingAvailability: store.isCheckingRequestCreationAvailability,
            hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
            didCreateRequest: false
        )
    }

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, unless a case says otherwise.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.test-credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeAvailabilityStore() -> RequestStore {
        makeStore()
    }

    private func publicActionsResponse(paused: Bool) -> Data {
        Data(#"{"paused":\#(paused)}"#.utf8)
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }

    /// Collapses runs of whitespace/newlines to a single space, so a
    /// source-text assertion checks adjacency of statements rather than
    /// their exact indentation or line breaks.
    private func normalized(_ source: String) -> String {
        source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked file rather than a copy.
    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
