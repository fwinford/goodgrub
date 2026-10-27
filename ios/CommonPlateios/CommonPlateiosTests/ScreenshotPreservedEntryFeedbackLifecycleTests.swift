//
//  ScreenshotPreservedEntryFeedbackLifecycleTests.swift
//  CommonPlateiosTests
//
//  W4-R4 F1 + F2: which analyses qualify a later analysis as a rerun, and
//  that the temporary preserved-entry feedback can never strand.
//

import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotPreservedEntryFeedbackLifecycleTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Harness

    /// Mirrors the tail of `RequestFoodView.beginScreenshotAnalysis` against
    /// the real `ScreenshotProposalStore` and a stubbed transport: begin a
    /// selection, analyze, then `guard let outcome, isCurrent(token)`, apply,
    /// and hand the outcome's eligibility to the feedback state. There is no
    /// UI-test target (`docs/testing.md`), so this is the seam that stands in
    /// for mounting the view.
    @MainActor
    private struct Form {
        let store: ScreenshotProposalStore
        var draft = RequestFoodFormDraft()
        var manualEdits = ScreenshotFieldManualEditState()
        var feedback = ScreenshotPreservedEntryFeedbackState()
        var screenshotChecked = false

        init(store: ScreenshotProposalStore) {
            self.store = store
        }

        /// The requester typed a location, so a later proposal for it is
        /// preserved by manual authority.
        mutating func requesterEditsLocation() {
            manualEdits.hasManuallyEditedLocation = true
        }

        enum Result {
            /// No outcome reached the apply step (failed, cancelled, nil).
            case noOutcome
            /// Outcome applied; the value is the scheduled cleanup generation.
            case applied(feedbackTimeoutGeneration: Int?)
        }

        @discardableResult
        mutating func runAnalysis(
            stub: ScreenshotProposalURLProtocol.Stub?,
            authority: String? = "an-authority",
            evidence: String = ScreenshotTestEvidence.eligibleCart,
            invalidateWhileInFlight: Bool = false
        ) async -> Result {
            if let stub { ScreenshotProposalURLProtocol.enqueue(stub) }
            let token = store.beginSelection(clearing: &draft, manualEdits: manualEdits)
            feedback.beginSelection()
            screenshotChecked = false

            let store = self.store
            let inputs = [ScreenshotTestEvidence.input(evidence)]
            let task = Task { @MainActor in
                await analyzeThroughExternalFallback(
                    store: store,
                    images: inputs,
                    participantAuthority: authority,
                    token: token
                )
            }
            if invalidateWhileInFlight {
                await Task.yield()
                store.invalidateCurrentSelection()
            }
            let outcome = await task.value

            guard let outcome, store.isCurrent(token) else { return .noOutcome }
            let applied = store.apply(outcome, manualEdits: manualEdits, to: &draft)
            if outcome.eligible { screenshotChecked = true }
            let generation = feedback.completeAnalysis(
                eligible: outcome.eligible,
                applying: applied
            )
            return .applied(feedbackTimeoutGeneration: generation)
        }
    }

    private func makeForm() -> Form {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let store = makeProductionWiredRequesterStore(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
        return Form(store: store)
    }

    private func eligibleStub(locationName: String = "Jasper Kane Cafe") -> ScreenshotProposalURLProtocol.Stub {
        let body: [String: Any] = [
            "eligible": true,
            "proposal": ["selectedDiningSpot": ["name": locationName, "address": "irrelevant"]],
        ]
        return .response(data: try! JSONSerialization.data(withJSONObject: body))
    }

    private func failingStub() -> ScreenshotProposalURLProtocol.Stub {
        .response(statusCode: 500, data: Data("{}".utf8))
    }

    private func assertNoFeedback(
        _ result: Form.Result,
        _ form: Form,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .applied(let generation) = result else {
            return XCTFail("expected an applied outcome", file: file, line: line)
        }
        XCTAssertNil(generation, file: file, line: line)
        XCTAssertFalse(form.feedback.isShowing, file: file, line: line)
    }

    private func assertFeedbackScheduled(
        _ result: Form.Result,
        _ form: Form,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .applied(let generation) = result else {
            return XCTFail("expected an applied outcome", file: file, line: line)
        }
        XCTAssertNotNil(generation, file: file, line: line)
        XCTAssertTrue(form.feedback.isShowing, file: file, line: line)
    }

    // MARK: - F2: rerun qualification

    func testIneligibleFirstOutcomeDoesNotEstablishPriorRunSoLaterEligibleAnalysisShowsNoFeedback() async {
        var form = makeForm()
        form.requesterEditsLocation()

        let first = await form.runAnalysis(stub: nil, evidence: ScreenshotTestEvidence.ineligible)
        assertNoFeedback(first, form)
        XCTAssertFalse(form.feedback.hasCompletedScreenshotAssistanceRun)
        XCTAssertFalse(form.screenshotChecked)

        let second = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(second, form)
        XCTAssertTrue(form.feedback.hasCompletedScreenshotAssistanceRun, "the first eligible analysis establishes the first completed run")
        XCTAssertTrue(form.screenshotChecked, "persistent checked state is unchanged")
    }

    func testFailedFirstAttemptDoesNotEstablishPriorRun() async {
        var form = makeForm()
        form.requesterEditsLocation()

        let first = await form.runAnalysis(stub: failingStub())
        guard case .noOutcome = first else { return XCTFail("a failed attempt must not reach apply") }
        XCTAssertFalse(form.feedback.hasCompletedScreenshotAssistanceRun)

        let second = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(second, form)
        XCTAssertTrue(form.feedback.hasCompletedScreenshotAssistanceRun)
    }

    func testCancelledFirstAttemptDoesNotEstablishPriorRun() async {
        var form = makeForm()
        form.requesterEditsLocation()

        let delayed = ScreenshotProposalURLProtocol.Stub.response(
            data: try! JSONSerialization.data(withJSONObject: ["eligible": true, "proposal": [String: Any]()]),
            delay: 0.3
        )
        let first = await form.runAnalysis(stub: delayed, invalidateWhileInFlight: true)
        guard case .noOutcome = first else { return XCTFail("a cancelled attempt must not reach apply") }
        XCTAssertFalse(form.feedback.hasCompletedScreenshotAssistanceRun)

        let second = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(second, form)
        XCTAssertTrue(form.feedback.hasCompletedScreenshotAssistanceRun)
    }

    func testNilOutcomeFirstAttemptDoesNotEstablishPriorRun() async {
        var form = makeForm()
        form.requesterEditsLocation()

        let first = await form.runAnalysis(stub: nil, authority: nil)
        guard case .noOutcome = first else { return XCTFail("a nil outcome must not reach apply") }
        XCTAssertEqual(form.store.notice, .unavailable, "the ordinary local-outcome notice, not a verification notice")
        XCTAssertFalse(form.feedback.hasCompletedScreenshotAssistanceRun)

        let second = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(second, form)
        XCTAssertTrue(form.feedback.hasCompletedScreenshotAssistanceRun)
    }

    func testEligibleThenEligibleRerunPreservingManualContentShowsFeedback() async {
        var form = makeForm()
        form.requesterEditsLocation()

        let first = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(first, form)
        XCTAssertTrue(form.feedback.hasCompletedScreenshotAssistanceRun)

        let rerun = await form.runAnalysis(stub: eligibleStub())
        assertFeedbackScheduled(rerun, form)
        XCTAssertTrue(form.screenshotChecked, "persistent ✓ Screenshot checked stays alongside the temporary message")
    }

    func testEligibleRerunThatPreservesNothingShowsNoFeedback() async {
        var form = makeForm()

        let first = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(first, form)

        // No manual edit, so the proposal is applied rather than preserved.
        let rerun = await form.runAnalysis(stub: eligibleStub())
        assertNoFeedback(rerun, form)
        XCTAssertTrue(form.screenshotChecked)
    }

    func testCompletedRunFlagAdvancesOnlyForEligibleOutcome() {
        let preserved = ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        var state = ScreenshotPreservedEntryFeedbackState()

        XCTAssertNil(state.completeAnalysis(eligible: false, applying: preserved))
        XCTAssertFalse(state.hasCompletedScreenshotAssistanceRun)
        XCTAssertFalse(state.isShowing)

        XCTAssertNil(state.completeAnalysis(eligible: true, applying: preserved))
        XCTAssertTrue(state.hasCompletedScreenshotAssistanceRun)

        // A later ineligible outcome neither shows feedback nor clears the
        // earlier completed eligible run.
        XCTAssertNil(state.completeAnalysis(eligible: false, applying: preserved))
        XCTAssertTrue(state.hasCompletedScreenshotAssistanceRun)
        XCTAssertNotNil(state.completeAnalysis(eligible: true, applying: preserved))
    }

    // MARK: - F1: temporary cleanup

    private func showingFeedback() -> (state: ScreenshotPreservedEntryFeedbackState, generation: Int) {
        let preserved = ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        var state = ScreenshotPreservedEntryFeedbackState()
        _ = state.completeAnalysis(eligible: true, applying: preserved)
        let generation = state.completeAnalysis(eligible: true, applying: preserved)!
        XCTAssertTrue(state.isShowing)
        return (state, generation)
    }

    func testNormalTimeoutClearsFeedback() {
        var (state, generation) = showingFeedback()
        state.clearAfterTimeout(ifCurrent: generation)
        XCTAssertFalse(state.isShowing)
    }

    func testFeedbackClearsAtTimeoutEvenWhenTheStoreTokenIsNoLongerCurrent() async {
        // The defect: cleanup gated on the store token stranded the message
        // once disappearance/disablement advanced the store generation. The
        // feedback state's own fence must clear regardless of token state.
        var form = makeForm()
        form.requesterEditsLocation()
        await form.runAnalysis(stub: eligibleStub())
        var draftForToken = RequestFoodFormDraft()
        let rerun = await form.runAnalysis(stub: eligibleStub())
        guard case .applied(let generation?) = rerun else { return XCTFail("expected feedback") }
        XCTAssertTrue(form.feedback.isShowing)

        let token = form.store.beginSelection(clearing: &draftForToken, manualEdits: form.manualEdits)
        form.store.invalidateCurrentSelection()
        XCTAssertFalse(form.store.isCurrent(token))

        form.feedback.clearAfterTimeout(ifCurrent: generation)
        XCTAssertFalse(form.feedback.isShowing)
    }

    func testViewDisappearanceRetiresVisibleFeedbackAndFencesItsCleanup() {
        var (state, generation) = showingFeedback()

        state.retire()
        XCTAssertFalse(state.isShowing)
        XCTAssertTrue(state.hasCompletedScreenshotAssistanceRun, "retiring is not a terminal reset")

        state.clearAfterTimeout(ifCurrent: generation)
        XCTAssertFalse(state.isShowing)
    }

    func testDisablingScreenshotAssistanceRetiresVisibleFeedback() async {
        var form = makeForm()
        form.requesterEditsLocation()
        await form.runAnalysis(stub: eligibleStub())
        let rerun = await form.runAnalysis(stub: eligibleStub())
        guard case .applied(let generation?) = rerun else { return XCTFail("expected feedback") }
        XCTAssertTrue(form.feedback.isShowing)

        form.store.setAIAssistanceEnabled(false)
        // The view's `.onChange(of: isAIAssistanceEnabled)` retires here.
        if !form.store.isAIAssistanceEnabled { form.feedback.retire() }
        XCTAssertFalse(form.feedback.isShowing)

        form.feedback.clearAfterTimeout(ifCurrent: generation)
        XCTAssertFalse(form.feedback.isShowing)
    }

    func testStaleCleanupFromOlderFeedbackDoesNotClearNewerFeedback() {
        let preserved = ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        var state = ScreenshotPreservedEntryFeedbackState()
        _ = state.completeAnalysis(eligible: true, applying: preserved)
        let older = state.completeAnalysis(eligible: true, applying: preserved)!
        let newer = state.completeAnalysis(eligible: true, applying: preserved)!
        XCTAssertNotEqual(older, newer)
        XCTAssertTrue(state.isShowing)

        state.clearAfterTimeout(ifCurrent: older)
        XCTAssertTrue(state.isShowing, "the older timeout must not clear newer feedback")

        state.clearAfterTimeout(ifCurrent: newer)
        XCTAssertFalse(state.isShowing)
    }

    func testStaleCleanupAfterTerminalReplacementLeavesReplacementStateUntouched() {
        let (state, staleGeneration) = showingFeedback()
        var mounted = RequestFoodMountedPresentationState(
            screenshotChecked: true,
            preservedEntryFeedback: state,
            expandedMealIndex: 1
        )
        let store = makeForm().store

        mounted.resetForTerminalRecovery(screenshotProposalStore: store)
        XCTAssertFalse(mounted.preservedEntryFeedback.isShowing)
        XCTAssertFalse(mounted.preservedEntryFeedback.hasCompletedScreenshotAssistanceRun)
        let replacement = mounted

        mounted.preservedEntryFeedback.clearAfterTimeout(ifCurrent: staleGeneration)
        XCTAssertEqual(mounted, replacement)

        // The replacement form's own first run still cannot show rerun feedback.
        XCTAssertNil(
            mounted.preservedEntryFeedback.completeAnalysis(
                eligible: true,
                applying: ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
            )
        )
    }

    func testSelectionGenerationTransitionFencesStaleCleanupFromNewerFeedbackState() {
        let preserved = ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        var state = ScreenshotPreservedEntryFeedbackState()
        _ = state.completeAnalysis(eligible: true, applying: preserved)
        let first = state.completeAnalysis(eligible: true, applying: preserved)!

        state.beginSelection()
        XCTAssertFalse(state.isShowing)
        let second = state.completeAnalysis(eligible: true, applying: preserved)!
        XCTAssertTrue(state.isShowing)

        state.clearAfterTimeout(ifCurrent: first)
        XCTAssertTrue(state.isShowing)
        state.clearAfterTimeout(ifCurrent: second)
        XCTAssertFalse(state.isShowing)
    }

    // MARK: - Wiring (source inspection; no UI-test target exists)

    func testViewWiringRetiresOnDisappearAndDisablementAndDoesNotGateCleanupOnStoreToken() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        let disappearStart = try XCTUnwrap(source.range(of: ".onDisappear {"))
        let disappearEnd = try XCTUnwrap(
            source.range(of: ".onChange(of: selectedScreenshotItems)", range: disappearStart.upperBound..<source.endIndex)
        )
        let disappearBlock = String(source[disappearStart.lowerBound..<disappearEnd.lowerBound])
        XCTAssertTrue(disappearBlock.contains("preservedEntryFeedback.retire()"))

        let disableStart = try XCTUnwrap(
            source.range(of: ".onChange(of: screenshotProposalStore.isAIAssistanceEnabled)")
        )
        let disableBlock = String(source[disableStart.lowerBound...].prefix(160))
        XCTAssertTrue(disableBlock.contains("preservedEntryFeedback.retire()"))

        let cleanupStart = try XCTUnwrap(source.range(of: "try? await Task.sleep(for: Self.preservedEntryFeedbackDuration)"))
        let cleanupEnd = try XCTUnwrap(
            source.range(of: "clearAfterTimeout", range: cleanupStart.upperBound..<source.endIndex)
        )
        let between = String(source[cleanupStart.upperBound..<cleanupEnd.lowerBound])
        XCTAssertFalse(between.contains("isCurrent"), "cleanup must be fenced only by the feedback generation")

        XCTAssertTrue(source.contains("eligible: outcome.eligible"))
    }

    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "expected \(relativePath) at \(url.path)")
        return url
    }
}
