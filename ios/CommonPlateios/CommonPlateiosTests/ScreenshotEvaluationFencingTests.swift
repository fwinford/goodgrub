//
//  ScreenshotEvaluationFencingTests.swift
//  CommonPlateiosTests
//
// W4-S3: stale/cancel/Settings fencing and `isApplying` timing across the
// Requester workflow's evaluation stage (eligibility + on-device OCR
// derivation). Before the shared-runtime refactor this stage ran in the view,
// before the store was called; it now runs inside `analyzeScreenshot`, so the
// guarantees the view used to provide are proved here against the real store:
//
// - a retired selection stops recognizing immediately and can never reach a
//   provider, local or external;
// - a newer selection wins over an older one still recognizing;
// - Settings Off during derivation retires the attempt;
// - `isApplying` covers exactly the provider attempt, never the derivation, so
//   the requester-visible `Analyzing screenshot…` timing is unchanged.
//
// All evidence is synthetic; recognition is stubbed and nothing touches Vision.
import Foundation
import XCTest
@testable import CommonPlateios

/// Recognizes synthetic text after a delay, counting every call.
@MainActor
final class SlowTextRecognizer: ScreenshotTextRecognizing {
    let delay: Duration
    private(set) var callCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func recognizeText(in image: ScreenshotPreparedImage) async -> String {
        callCount += 1
        // A cancelled sleep returns immediately; the workflow then observes the
        // cancellation between screenshots.
        try? await Task.sleep(for: delay)
        return String(decoding: image.sourceData, as: UTF8.self)
    }
}

@MainActor
final class ScreenshotEvaluationFencingTests: XCTestCase {
    private let environment = testQualifiableEnvironment
    private let noManualEdits = ScreenshotFieldManualEditState()

    private struct Harness {
        let store: ScreenshotProposalStore
        let recognizer: SlowTextRecognizer
        let local: StubLocalProvider
        let external: StubExternalProvider
    }

    private func makeHarness(
        recognizerDelay: Duration,
        localBehavior: StubLocalProvider.Behavior
    ) -> Harness {
        let recognizer = SlowTextRecognizer(delay: recognizerDelay)
        let local = StubLocalProvider(behavior: localBehavior)
        let external = StubExternalProvider()
        let runtime = ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(recognizer: recognizer),
            localProvider: local,
            externalProvider: external,
            qualification: qualifiedRegistry(environment: environment),
            environment: environment,
            localAttemptTimeout: .seconds(5)
        )
        let client = APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: runtime
        )
        return Harness(store: store, recognizer: recognizer, local: local, external: external)
    }

    private var usefulOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: "Jasper Kane Cafe",
            foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
            mealSwipes: nil
        )
    }

    private func begin(_ store: ScreenshotProposalStore) -> ScreenshotSelectionToken {
        var draft = RequestFoodFormDraft()
        return store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
    }

    func testRetiringDuringDerivationStopsRecognitionAndNeverReachesAProvider() async {
        let harness = makeHarness(recognizerDelay: .milliseconds(150), localBehavior: .output(usefulOutput))
        let token = begin(harness.store)
        let task = Task {
            await harness.store.analyzeScreenshot(
                images: ScreenshotTestEvidence.inputs(5),
                participantAuthority: { "an-authority" },
                token: token
            )
        }
        try? await Task.sleep(for: .milliseconds(200))

        harness.store.invalidateCurrentSelection()

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertLessThan(harness.recognizer.callCount, 5, "a retired selection stops recognizing the rest of its screenshots")
        XCTAssertEqual(harness.local.extractCallCount, 0)
        XCTAssertEqual(harness.external.analyzeCallCount, 0)
        XCTAssertFalse(harness.store.isApplying)
        XCTAssertNil(harness.store.notice)
    }

    func testSettingsOffDuringDerivationRetiresTheAttemptWithoutAProviderCall() async {
        let harness = makeHarness(recognizerDelay: .milliseconds(120), localBehavior: .fail(StubLocalProvider.StubError()))
        let token = begin(harness.store)
        let task = Task {
            await harness.store.analyzeScreenshot(
                images: ScreenshotTestEvidence.inputs(3),
                participantAuthority: { "an-authority" },
                token: token
            )
        }
        try? await Task.sleep(for: .milliseconds(60))

        harness.store.setAIAssistanceEnabled(false)

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertFalse(harness.store.isCurrent(token))
        XCTAssertEqual(harness.local.extractCallCount, 0)
        XCTAssertEqual(harness.external.analyzeCallCount, 0, "the local failure that would have fallen through to external AI never happened")
    }

    func testANewerSelectionWinsOverAnOlderSelectionStillRecognizing() async {
        let harness = makeHarness(recognizerDelay: .milliseconds(150), localBehavior: .output(usefulOutput))
        var draft = RequestFoodFormDraft()
        let older = harness.store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task {
            await harness.store.analyzeScreenshot(
                images: ScreenshotTestEvidence.inputs(3),
                participantAuthority: { "an-authority" },
                token: older
            )
        }
        try? await Task.sleep(for: .milliseconds(40))

        let newer = harness.store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let newerOutcome = await harness.store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(byte: 9)],
            participantAuthority: { "an-authority" },
            token: newer
        )

        let olderOutcome = await olderTask.value
        XCTAssertNil(olderOutcome, "the older selection must be dropped even though it was mid-recognition")
        XCTAssertNotNil(newerOutcome)
        XCTAssertTrue(harness.store.isCurrent(newer))
        XCTAssertEqual(harness.local.extractCallCount, 1, "only the newer selection reached the provider")
        XCTAssertEqual(harness.local.lastInput?.selection.items.map { $0.image.data.first }, [9])
        XCTAssertFalse(harness.store.isApplying)
    }

    /// `isApplying` — which drives `Analyzing screenshot…` — covers the provider
    /// attempt only. Recognition is not counted, exactly as when it ran in the
    /// view before the store was called.
    func testIsApplyingCoversTheProviderAttemptButNotTheDerivation() async {
        let harness = makeHarness(
            recognizerDelay: .milliseconds(200),
            localBehavior: .delayed(.milliseconds(300), usefulOutput)
        )
        let token = begin(harness.store)
        let task = Task {
            await harness.store.analyzeScreenshot(
                images: [ScreenshotTestEvidence.input()],
                participantAuthority: { "an-authority" },
                token: token
            )
        }

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.recognizer.callCount, 1, "derivation is under way")
        XCTAssertEqual(harness.local.extractCallCount, 0)
        XCTAssertFalse(harness.store.isApplying, "recognition is not the in-flight provider attempt")

        // t≈350ms: recognition ended at ≈200ms and the 300ms provider attempt ends at ≈500ms.
        try? await Task.sleep(for: .milliseconds(270))
        XCTAssertEqual(harness.local.extractCallCount, 1, "the provider attempt is under way")
        XCTAssertTrue(harness.store.isApplying)

        let outcome = await task.value
        XCTAssertNotNil(outcome)
        XCTAssertFalse(harness.store.isApplying)
    }

    func testAnIneligibleSelectionIsDecidedAfterDerivationWithoutTouchingAnyProvider() async {
        let harness = makeHarness(recognizerDelay: .milliseconds(20), localBehavior: .output(usefulOutput))
        let token = begin(harness.store)

        let outcome = await harness.store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome, ScreenshotProposalOutcome(eligible: false, proposal: .empty))
        XCTAssertEqual(harness.recognizer.callCount, 1)
        XCTAssertEqual(harness.local.extractCallCount, 0)
        XCTAssertEqual(harness.external.analyzeCallCount, 0)
    }
}
