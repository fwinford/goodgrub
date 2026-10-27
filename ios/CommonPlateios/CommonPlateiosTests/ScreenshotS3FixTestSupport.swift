//
//  ScreenshotS3FixTestSupport.swift
//  CommonPlateiosTests
//
// Shared helpers for the W4-S3 fix-round suites (fallback-authority timing,
// external-permission binding, deadline enforcement,
// qualification fingerprinting): a mutable authority holder, a bounded polling
// wait, a genuinely non-cooperative local provider, a recognizer that runs a
// hook, and a real store over an injected runtime. All evidence is synthetic.
import Foundation
import XCTest
@testable import CommonPlateios

/// The requester's current participant authority as a test controls it, and how
/// often the store asked for it.
@MainActor
final class AuthorityBox {
    var value: String?
    private(set) var readCount = 0

    init(_ value: String? = "an-authority") {
        self.value = value
    }

    func read() -> String? {
        readCount += 1
        return value
    }
}

/// Stands in for Vision and runs a hook when recognition starts, so a test can
/// change the world while evidence derivation is in flight.
struct HookedTextRecognizer: ScreenshotTextRecognizing {
    let onRecognize: @MainActor () -> Void

    func recognizeText(in image: ScreenshotPreparedImage) async -> String {
        await MainActor.run { onRecognize() }
        return String(decoding: image.sourceData, as: UTF8.self)
    }
}

/// A local provider that IGNORES cooperative cancellation: `extract` suspends on
/// a plain checked continuation (no cancellation handler, no `Task.sleep`), so
/// only `release` lets it finish — exactly the provider a nominal timeout cannot
/// trust.
@MainActor
final class NonCooperativeLocalProvider: ScreenshotLocalProvider {
    typealias Workflow = RequesterOrderWorkflow

    let identity = ScreenshotProviderIdentity.nonShipping(id: "test.non-cooperative", strategyVersion: "1")
    let inputMode: ScreenshotInputMode = .ocrFlattenedText
    var output: RequesterOrderRawOutput
    private(set) var startCount = 0
    private(set) var completionCount = 0
    private var gate: CheckedContinuation<Void, Never>?

    init(output: RequesterOrderRawOutput) {
        self.output = output
    }

    /// `extract` has started and not yet finished.
    var isRunning: Bool { startCount > completionCount }

    func availability() -> ScreenshotLocalAvailability { .available }

    func extract(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>
    ) async throws -> ScreenshotProviderResult<RequesterOrderRawOutput> {
        startCount += 1
        await withCheckedContinuation { gate = $0 }
        completionCount += 1
        return ScreenshotProviderResult(output: output)
    }

    /// Lets the provider finish, as a late completion.
    func release() {
        gate?.resume()
        gate = nil
    }
}

/// Polls until `condition` holds, yielding to the scheduler between checks; fails
/// the test (rather than hanging) after `timeout`.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets scheduled work (including a released provider's late completion) run to
/// quiescence before a test asserts that nothing observable happened.
@MainActor
func letScheduledWorkSettle() async {
    for _ in 0..<10 {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A real `ScreenshotProposalStore` over an injected runtime (no network: every
/// external provider in these suites is a stub).
@MainActor
func makeStoreOver(
    _ runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>
) -> ScreenshotProposalStore {
    let client = APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))
    return ScreenshotProposalStore(
        availability: .enabledForTesting(),
        service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
        preferences: InMemoryScreenshotProposalPreferencesStorage(),
        runtime: runtime
    )
}

/// What the requester view does at the start of one attempt.
@MainActor
func beginAttempt(_ store: ScreenshotProposalStore) -> ScreenshotSelectionToken {
    var draft = RequestFoodFormDraft()
    return store.beginSelection(
        clearing: &draft,
        manualEdits: ScreenshotFieldManualEditState()
    )
}

let usefulRequesterOutput = RequesterOrderRawOutput(
    visibleVenueText: "Jasper Kane Cafe",
    foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
    mealSwipes: nil
)

let emptyRequesterOutput = RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil)
