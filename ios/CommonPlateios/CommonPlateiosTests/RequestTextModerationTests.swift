//
//  RequestTextModerationTests.swift
//  CommonPlateiosTests
//
// W4-U1.1 requester text-filtering refusal. The backend answers requester
// text that matches its participant-text filter with the stable, definitive,
// pre-mutation `REQUEST_TEXT_NOT_ALLOWED`. This suite proves iOS consumes it as
// its own form state and not as a generic failure or an ambiguous write:
//
// - the D2 classification: definitive non-create for a fresh transmission, but
//   never proof on its own during recovery of an issued identity;
// - the form state: scoped to the exact submitted authored text and the exact
//   participant authority, retired for good by any edit, menu-path or
//   swipe-count change, or identity replacement;
// - the presentation contract, by source inspection (this project has no
//   UI-test target — see `docs/testing.md`).
//
// Reuses `RequestFetchingURLProtocol` from `RequestFetchingTests.swift`.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestTextModerationTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"
    private let participantIdentifierA = "64c0000000000000000000a1"
    private let baseURL = URL(string: "https://commonplate.test")!
    private let refusalCode = "REQUEST_TEXT_NOT_ALLOWED"

    private static let createPath = "/api/request"
    private static let terminalPath = "/api/request-operation/terminal"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Contract values

    func testTheApprovedCopyIsExactAndSharedWithTheBackendRefusalMessage() throws {
        XCTAssertEqual(
            RequestTextModeration.noticeCopy,
            "Keep request details respectful and food-related."
        )
        XCTAssertEqual(RequestTextModeration.sectionHeading, "What would you like?")
        XCTAssertEqual(RequestOperationErrorCode.textNotAllowed, "REQUEST_TEXT_NOT_ALLOWED")

        // The backend's own message is the same sentence, so the two cannot drift.
        let route = try source(named: "src/createRequestRoute.ts")
        XCTAssertTrue(route.contains(#""Keep request details respectful and food-related.""#))
        XCTAssertTrue(route.contains(#"export const REQUEST_TEXT_NOT_ALLOWED_CODE = "REQUEST_TEXT_NOT_ALLOWED""#))
    }

    func testOnlyTheStableCodeIsTheRefusalNeverAMessageOrAnotherFailure() {
        XCTAssertTrue(RequestTextModeration.isRefusal(
            RequestServiceError.serverError(code: refusalCode, message: "anything")
        ))
        // The message never decides it.
        XCTAssertFalse(RequestTextModeration.isRefusal(
            RequestServiceError.serverError(
                code: "INVALID_REQUEST",
                message: RequestTextModeration.noticeCopy
            )
        ))
        for other: RequestServiceError in [
            .serverError(code: "REQUEST_CREATION_FAILED", message: "x"),
            .serverError(code: "REQUEST_LIMIT_REACHED", message: "x"),
            .serverError(code: "RATE_LIMITED", message: "x"),
            .ambiguousCreateOutcome(underlying: URLError(.timedOut)),
            .operationInProgress,
            .notFound,
            .transport(underlying: URLError(.notConnectedToInternet)),
        ] {
            XCTAssertFalse(RequestTextModeration.isRefusal(other), "\(other)")
        }
        XCTAssertFalse(RequestTextModeration.isRefusal(CancellationError()))
        XCTAssertFalse(RequestTextModeration.isRefusal(URLError(.timedOut)))
    }

    // MARK: - D2 classification

    func testD2ClassificationIsDefinitiveForAFreshAttemptButNeverRecoveryProof() {
        let code = RequestOperationErrorCode.textNotAllowed
        // A fresh transmission that received it created nothing.
        XCTAssertTrue(RequestOperationErrorCode.isDefinitiveNonCreate(code))
        // During recovery it is only ever answered after an empty identity
        // lookup, so it is routed to exact terminal reconciliation instead of
        // being taken as proof.
        XCTAssertTrue(RequestOperationErrorCode.isPostLookupRefusal(code))
        // It is not terminal authority, a pre-ledger refusal, or write-uncertain.
        XCTAssertFalse(RequestOperationErrorCode.isTerminalOperationRetirement(code))
        XCTAssertFalse(RequestOperationErrorCode.isPreLedgerRefusal(code))
        XCTAssertFalse(RequestOperationErrorCode.isWriteUncertain(code))
    }

    func testAFreshRefusedCreateRetiresItsRecordAndLeavesNothingBlockingOrInserted() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 422,
            data: errorBody(code: refusalCode)
        ))

        do {
            try await store.createRequest(mealPayload("a refused meal"))
            XCTFail("Expected the refusal")
        } catch {
            XCTAssertTrue(RequestTextModeration.isRefusal(error), "\(error)")
        }

        // Definitive non-create: the durable record this attempt wrote is
        // retired, nothing blocks the next intentional submission, and nothing
        // was inserted into the collection or presented as created.
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.createdRequestContinuity)
        // Exactly one create transmission, and no terminal-reconciliation call.
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == Self.createPath }.count,
            1
        )
        XCTAssertFalse(RequestFetchingURLProtocol.capturedRequestedPaths.contains(Self.terminalPath))
    }

    func testARefusalDuringRecoveryIsNotProofAndStaysPendingWhenTerminalAuthorityIsInconclusive() async throws {
        let storage = savedStorage(operationId: "U11-REPLAY-REFUSED")
        let before = storage.load()
        let store = makeStore(storage: storage)
        // The replay of the issued identity is answered with the refusal...
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 422,
            data: errorBody(code: refusalCode)
        ))
        // ...and exact terminal reconciliation cannot answer this time.
        RequestFetchingURLProtocol.enqueue(.failure(.timedOut))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            [Self.createPath, Self.terminalPath]
        )
        // An earlier transmission may still commit, so the refusal alone never
        // retires the operation or lets a replacement begin.
        XCTAssertEqual(storage.load(), before)
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
    }

    func testARefusalDuringRecoveryConvergesOnTerminalAuthorityAnsweringCreated() async throws {
        // The original transmission committed (before the filter's rules could
        // have refused it); recovery must answer CREATED, not the refusal.
        let storage = savedStorage(operationId: "U11-REPLAY-LATE-COMMIT")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 422,
            data: errorBody(code: refusalCode)
        ))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"outcome":"created","request":\#(requestObject(id: "late-commit"))}"#.utf8)
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testARefusalDuringRecoveryConvergesOnTerminalNoCreateWithTheDraftRecoverable() async throws {
        let storage = savedStorage(operationId: "U11-REPLAY-NO-CREATE")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 422,
            data: errorBody(code: refusalCode)
        ))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"outcome":"not-created"}"#.utf8)
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // The payload was known and readable (Path A), so the requester can
        // return to the exact request they composed.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedRecoverable)
    }

    // MARK: - Active authored text

    func testActiveAuthoredTextIsExactlyWhatTheSubmittedRequestCarries() {
        var draft = RequestFoodFormDraft(
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealEntries: [
                MealItem(name: "Meal one", details: "extra spicy"),
                MealItem(name: "Meal two"),
                MealItem(name: "hidden three"),
                MealItem(name: "hidden four"),
                MealItem(name: "hidden five"),
            ],
            orderDetails: "inactive path text"
        )
        XCTAssertEqual(
            RequestTextModeration.activeAuthoredTexts(in: draft),
            ["Meal one", "extra spicy", "Meal two", ""]
        )

        draft.menuPath = .diningDollars
        XCTAssertEqual(RequestTextModeration.activeAuthoredTexts(in: draft), ["inactive path text"])
    }

    // MARK: - Scoped, permanently-clearing form state

    func testTheNoticeIsCurrentOnlyForTheExactSubmittedTextAndAuthority() {
        let submitted = draft(meals: ["Meal one", "Meal two"])
        let state = RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)

        XCTAssertTrue(RequestTextModeration.isCurrent(state, draft: submitted, authority: authorityA))
        XCTAssertFalse(RequestTextModeration.isCurrent(nil, draft: submitted, authority: authorityA))
        // The draft is not touched by the state — it is simply compared.
        XCTAssertEqual(submitted, draft(meals: ["Meal one", "Meal two"], pickupTime: submitted.preferredPickupTime))
    }

    func testEditingAnyModeratedValueRetiresTheNoticeForGoodEvenIfRestored() {
        let submitted = draft(meals: ["Meal one", "Meal two"])
        let state: RequestTextModerationState? =
            RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)

        // Editing the first meal's item.
        var edited = submitted
        edited.mealEntries[0].name = "Meal one!"
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: edited, authority: authorityA))

        // Editing the second meal's details.
        var details = submitted
        details.mealEntries[1].details = "no onions"
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: details, authority: authorityA))

        // Even a whitespace-only edit is an edit.
        var whitespace = submitted
        whitespace.mealEntries[0].name += " "
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: whitespace, authority: authorityA))

        // Once cleared it never returns on its own, even when the exact
        // original text is restored: reconciling `nil` stays `nil`.
        let cleared = RequestTextModeration.reconciled(state, draft: edited, authority: authorityA)
        XCTAssertNil(cleared)
        XCTAssertNil(RequestTextModeration.reconciled(cleared, draft: submitted, authority: authorityA))
    }

    func testEditingAnInactiveHiddenMealDoesNotDisturbTheNotice() {
        var submitted = draft(meals: ["Meal one", "Meal two"])
        submitted.mealEntries[3].name = "hidden before"
        let state: RequestTextModerationState? =
            RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)

        // That text was never submitted, so it was never moderated.
        var edited = submitted
        edited.mealEntries[3].name = "hidden after"
        XCTAssertEqual(
            RequestTextModeration.reconciled(state, draft: edited, authority: authorityA),
            state
        )
    }

    func testChangesToWhichAuthoredTextIsActiveClearTheNotice() {
        let submitted = draft(meals: ["Meal one", "Meal two"])
        let state: RequestTextModerationState? =
            RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)

        // Menu-path change: a different authored text becomes active.
        var otherPath = submitted
        otherPath.menuPath = .diningDollars
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: otherPath, authority: authorityA))

        // Swipe-count change: the set of active Meals changes.
        var fewerMeals = submitted
        fewerMeals.mealSwipes = 1
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: fewerMeals, authority: authorityA))
        var moreMeals = submitted
        moreMeals.mealSwipes = 3
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: moreMeals, authority: authorityA))
    }

    func testAReplacedOrDiscardedParticipantCannotInheritTheRefusal() {
        let submitted = draft(meals: ["Meal one", "Meal two"])
        let state: RequestTextModerationState? =
            RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)

        // A different verified participant (Change Email).
        XCTAssertFalse(RequestTextModeration.isCurrent(state, draft: submitted, authority: authorityB))
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: submitted, authority: authorityB))
        // No participant at all (identity removed).
        XCTAssertFalse(RequestTextModeration.isCurrent(state, draft: submitted, authority: nil))
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: submitted, authority: nil))
        // And a late answer for a replaced identity is stale on arrival.
        let lateRefusal = RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)
        XCTAssertFalse(RequestTextModeration.isCurrent(lateRefusal, draft: submitted, authority: authorityB))
    }

    func testDiningDollarsRefusalIsScopedToTheOrderDetails() {
        var submitted = RequestFoodFormDraft(
            menuPath: .diningDollars,
            mealEntries: ["unused"],
            orderDetails: "a refused order",
            diningDollarsText: "12.00"
        )
        let state: RequestTextModerationState? =
            RequestTextModeration.state(afterRefusalOf: submitted, authority: authorityA)
        XCTAssertEqual(state?.moderatedTexts, ["a refused order"])

        // The estimate is not authored text; editing it leaves the notice alone.
        submitted.diningDollarsText = "13.00"
        XCTAssertEqual(
            RequestTextModeration.reconciled(state, draft: submitted, authority: authorityA),
            state
        )
        submitted.orderDetails = "a different order"
        XCTAssertNil(RequestTextModeration.reconciled(state, draft: submitted, authority: authorityA))
    }

    func testTheMountedPresentationStateResetsTheNoticeWithEverythingElse() {
        var mounted = RequestFoodMountedPresentationState()
        mounted.textModeration = RequestTextModeration.state(
            afterRefusalOf: draft(meals: ["Meal one", "Meal two"]),
            authority: authorityA
        )
        mounted.submissionError = .creationFailed
        XCTAssertNotNil(mounted.textModeration)

        mounted.resetForTerminalRecovery(screenshotProposalStore: makeScreenshotProposalStore())

        XCTAssertNil(mounted.textModeration)
        XCTAssertNil(mounted.submissionError)
    }

    // MARK: - Presentation contract (source inspection; no UI-test target)

    func testRefusalIsAFormStateNotAFailureSummaryHapticOrSubmissionError() throws {
        let view = try source(named: "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        // The refusal is recognized first in the real catch path, and returns
        // before the generic outcome mapping that produces the failure summary,
        // the error haptic, and `submissionError`.
        let catchStart = try XCTUnwrap(view.range(of: "if RequestTextModeration.isRefusal(error) {"))
        let outcomeStart = try XCTUnwrap(view.range(
            of: "let outcome = Self.submissionFailureOutcome(",
            range: catchStart.upperBound..<view.endIndex
        ))
        let refusalBranch = String(view[catchStart.lowerBound..<outcomeStart.lowerBound])
        XCTAssertTrue(refusalBranch.contains("presentTextModerationNotice("))
        XCTAssertTrue(refusalBranch.contains("return"))
        XCTAssertFalse(refusalBranch.contains("isShowingFailureSummary = true"))
        XCTAssertFalse(refusalBranch.contains("CommonPlateHaptics"))
        XCTAssertFalse(refusalBranch.contains("submissionError ="))

        // A new submission supersedes any earlier notice, and the authority is
        // captured before the first suspension point.
        let submitStart = try XCTUnwrap(view.range(of: "private func submit(draftSnapshot"))
        let submitHead = String(view[submitStart.lowerBound..<catchStart.lowerBound])
        XCTAssertTrue(submitHead.contains("textModeration = nil"))
        XCTAssertTrue(submitHead.contains("let submittedAuthority = identityStore.currentAuthority()"))
        let capture = try XCTUnwrap(submitHead.range(of: "let submittedAuthority"))
        let firstSuspension = try XCTUnwrap(submitHead.range(of: "try await"))
        XCTAssertLessThan(capture.lowerBound, firstSuspension.lowerBound)
    }

    func testTheNoticeIsASectionBlockAboveTheMealFieldsAndNeverAModal() throws {
        let view = try source(named: "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        // Heading, then the notice directly beneath it.
        let section = try XCTUnwrap(view.range(of: "private var textModerationSection: some View {"))
        let body = String(view[section.lowerBound...].prefix(1_600))
        let heading = try XCTUnwrap(body.range(of: "RequestTextModeration.sectionHeading"))
        let notice = try XCTUnwrap(body.range(of: "RequestTextModeration.noticeCopy"))
        XCTAssertLessThan(heading.lowerBound, notice.lowerBound)
        // VoiceOver attention moves to the notice itself.
        XCTAssertTrue(body.contains(".accessibilityFocused($isTextModerationNoticeFocused)"))
        XCTAssertTrue(body.contains(".accessibilityAddTraits(.isHeader)"))
        // Never blames a field, and never a modal/sheet/alert/new action.
        for forbidden in [".alert(", ".sheet(", ".fullScreenCover(", ".confirmationDialog(", "Button("] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }

        // Placement: ahead of the Meal cards (Meal Exchange) and the order
        // details (Dining Dollars only).
        let mealFields = try XCTUnwrap(view.range(of: "private func mealExchangeFields("))
        let mealBody = String(view[mealFields.lowerBound...].prefix(2_400))
        let moderation = try XCTUnwrap(mealBody.range(of: "textModerationSection"))
        let cards = try XCTUnwrap(mealBody.range(of: "ForEach(Array(draft.activeMealEntryIndices)"))
        XCTAssertLessThan(moderation.lowerBound, cards.lowerBound)

        let diningFields = try XCTUnwrap(view.range(of: "private func diningDollarsOnlyFields("))
        let diningBody = String(view[diningFields.lowerBound...].prefix(900))
        let diningModeration = try XCTUnwrap(diningBody.range(of: "textModerationSection"))
        let orderDetails = try XCTUnwrap(diningBody.range(of: "RequesterFormFieldContainer("))
        XCTAssertLessThan(diningModeration.lowerBound, orderDetails.lowerBound)
    }

    func testPostRequestStaysGovernedByOrdinaryCompletenessAndInFlightRules() {
        let complete = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealEntries: ["A meal"]
        )
        // The refusal produces no submission error at all, so submission stays
        // enabled for a complete draft and disabled only by the ordinary rules.
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: complete,
            submissionError: nil,
            isCreating: false
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: complete,
            submissionError: nil,
            isCreating: true
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: RequestFoodFormDraft(selectedDiningSpot: complete.selectedDiningSpot),
            submissionError: nil,
            isCreating: false
        ))
    }

    func testTheNoticeIsClearedByDraftAndIdentityChangesInTheMountedView() throws {
        let view = try source(named: "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let onChange = try XCTUnwrap(view.range(of: ".onChange(of: draft) { _, _ in"))
        let draftHook = String(view[onChange.lowerBound...].prefix(900))
        XCTAssertTrue(draftHook.contains("RequestTextModeration.reconciled("))
        // The view already has an identity hook for verification continuation
        // (`{ previous, current in`); the moderation hook is the separate one.
        let identityHook = try XCTUnwrap(view.range(of: ".onChange(of: identityStore.identity) { _, _ in"))
        XCTAssertTrue(String(view[identityHook.lowerBound...].prefix(500)).contains("RequestTextModeration.reconciled("))
        // A stale notice is also never drawn at render time.
        XCTAssertTrue(view.contains("private var currentTextModeration: RequestTextModerationState?"))
        XCTAssertTrue(view.contains("if currentTextModeration != nil {"))
    }

    // MARK: - Helpers

    private func draft(
        meals: [String],
        pickupTime: Date = Date(timeIntervalSince1970: 0)
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: pickupTime,
            mealSwipes: meals.count,
            mealEntries: meals
        )
    }

    private func makeStore(storage: PendingRequestOperationStorage) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { [authorityA] in authorityA },
            participantAuthorityRejected: {},
            operationStorage: storage
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            session: URLSession(configuration: configuration)
        ))
    }

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
            operationAuthority: RequestOperationAuthorityIdentity(
                origin: RequestService.operationAuthorityOrigin(for: baseURL),
                ledger: RequestFetchingURLProtocol.defaultOperationLedger
            ),
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

    private func requestObject(id: String, status: String = "open") -> String {
        """
        {"id":"\(id)","vendor":"Jasper Kane Cafe","food":"Meal","pickupWindowText":"ASAP","mealSwipes":1,"menuPath":"meal-exchange","mealItems":["Meal"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"\(status)","createdAt":"2026-09-16T17:00:00.000Z","expiresAt":"2026-09-16T20:00:00.000Z"}
        """
    }

    private func errorBody(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"backend detail","fields":null}}"#.utf8)
    }

    /// Repository file text, located from this test file's own path.
    private func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        // A missing source file is a failure, never a skip: a skipped
        // source-inspection test would silently stop proving its contract.
        throw SourceNotFound(relativePath: relativePath)
    }

    private struct SourceNotFound: Error, CustomStringConvertible {
        let relativePath: String
        var description: String { "Repository source not found from \(#filePath): \(relativePath)" }
    }
}
