//
//  ScreenshotAssistanceTestSupport.swift
//  CommonPlateiosTests
//
// W4-S3 shared test support: synthetic screenshots, a synthetic text recognizer,
// stub Requester local/external providers that count every call, and the
// two-phase requester interaction (local attempt, then the explicit
// `Use external AI` tap). All evidence here is synthetic — no real screenshot,
// OCR, or order content.
//
// A synthetic screenshot's `sourceData` carries its synthetic "recognizable
// text" as UTF-8 and its normalized `data` is a short identity byte, so a test
// can tell screenshots apart by `data.first` while `SyntheticTextRecognizer`
// stands in for Vision. Every stub provider is `.nonShipping`: it can be
// qualified only by a registry built with `injectedForTesting`.
import Foundation
import XCTest
@testable import CommonPlateios

enum ScreenshotTestEvidence {
    /// Passes the deterministic cart rule and names exactly one catalog vendor.
    static let eligibleCart = "Your Pickup Order\nContinue to Checkout\nJasper Kane Cafe"
    /// Eligible, but names no catalog vendor — so an empty provider output
    /// leaves the proposal genuinely empty (a vendor grounded in OCR evidence
    /// is a valid proposal field even when the provider returns nothing).
    static let eligibleCartWithoutVendor = "Your Pickup Order\nContinue to Checkout"
    /// Fails the legibility floor, so it is policy-ineligible.
    static let ineligible = "hello"

    static func input(
        _ evidence: String = eligibleCart,
        byte: UInt8 = 1
    ) -> ScreenshotPreparedImage {
        ScreenshotPreparedImage(sourceData: Data(evidence.utf8), data: Data([byte]), mimeType: "image/jpeg")
    }

    static func inputs(_ count: Int, evidence: (Int) -> String = { _ in eligibleCart }) -> [ScreenshotPreparedImage] {
        (0..<count).map { input(evidence($0 + 1), byte: UInt8($0 + 1)) }
    }
}

/// Stands in for Vision: reads the synthetic text a test embedded in
/// `sourceData`.
struct SyntheticTextRecognizer: ScreenshotTextRecognizing {
    func recognizeText(in image: ScreenshotPreparedImage) async -> String {
        String(decoding: image.sourceData, as: UTF8.self)
    }
}

/// A Requester local provider with scripted behavior and a call counter.
@MainActor
final class StubLocalProvider: ScreenshotLocalProvider {
    typealias Workflow = RequesterOrderWorkflow

    enum Behavior {
        case output(RequesterOrderRawOutput)
        case fail(Error)
        case hang
        case delayed(Duration, RequesterOrderRawOutput)
    }

    struct StubError: Error {}

    static let stubIdentity = ScreenshotProviderIdentity.nonShipping(id: "test.stub-local", strategyVersion: "1")

    var identity: ScreenshotProviderIdentity = StubLocalProvider.stubIdentity
    var inputMode: ScreenshotInputMode
    var availabilityValue: ScreenshotLocalAvailability
    var behavior: Behavior
    /// Runs when `extract` starts, before its scripted behavior — a hook a test
    /// uses to change the world while the local attempt is in flight.
    var onExtract: (() -> Void)?
    private(set) var extractCallCount = 0
    private(set) var availabilityCallCount = 0
    private(set) var lastInput: ScreenshotProviderInput<RequesterOrderWorkflow>?

    init(
        inputMode: ScreenshotInputMode = .ocrFlattenedText,
        availability: ScreenshotLocalAvailability = .available,
        behavior: Behavior
    ) {
        self.inputMode = inputMode
        self.availabilityValue = availability
        self.behavior = behavior
    }

    /// The recognized text each screenshot handed to `extract` carried, in the
    /// order the provider received them.
    var lastEvidenceTexts: [String]? {
        lastInput.map { $0.derived.orderedTexts(for: $0.selection) }
    }

    func availability() -> ScreenshotLocalAvailability {
        availabilityCallCount += 1
        return availabilityValue
    }

    func extract(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>
    ) async throws -> ScreenshotProviderResult<RequesterOrderRawOutput> {
        extractCallCount += 1
        lastInput = input
        onExtract?()
        switch behavior {
        case .output(let output):
            return ScreenshotProviderResult(output: output)
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw StubError()
        case .delayed(let delay, let output):
            try await Task.sleep(for: delay)
            return ScreenshotProviderResult(output: output)
        }
    }
}

/// A Requester external provider with scripted behavior and a call counter.
@MainActor
final class StubExternalProvider: ScreenshotExternalProvider {
    typealias Workflow = RequesterOrderWorkflow

    var identity: ScreenshotProviderIdentity = .nonShipping(id: "test.stub-external", strategyVersion: "1")
    var inputMode: ScreenshotInputMode = .directImageMultimodal
    var result: Result<ScreenshotProposalOutcome, Error>
    var delay: Duration = .zero
    private(set) var analyzeCallCount = 0
    private(set) var lastInput: ScreenshotProviderInput<RequesterOrderWorkflow>?

    init(result: Result<ScreenshotProposalOutcome, Error> = .success(ScreenshotProposalOutcome(eligible: true, proposal: .empty))) {
        self.result = result
    }

    /// The screenshots the last external attempt was handed, in order.
    var lastImages: [ScreenshotPreparedImage] {
        lastInput?.selection.items.map(\.image) ?? []
    }

    func analyze(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ScreenshotProposalOutcome> {
        analyzeCallCount += 1
        lastInput = input
        if delay > .zero { try await Task.sleep(for: delay) }
        return ScreenshotProviderResult(output: try result.get())
    }
}

/// A registry that qualifies exactly the Requester combination the given
/// provider/mode/environment present, for tests that must exercise the local
/// path. Only `injectedForTesting` can qualify a `.nonShipping` provider;
/// production is never made reachable this way.
func qualifiedRegistry(
    provider: ScreenshotProviderIdentity = StubLocalProvider.stubIdentity,
    inputMode: ScreenshotInputMode = .ocrFlattenedText,
    workflow: ScreenshotWorkflowIdentity = RequesterOrderWorkflow.identity,
    implementationFingerprint: String = ScreenshotQualificationFingerprint.current,
    environment: ScreenshotDeviceEnvironment
) -> ScreenshotQualificationRegistry {
    .injectedForTesting(entries: [
        ScreenshotQualificationEntry(
            key: ScreenshotQualificationKey(
                workflow: workflow,
                provider: provider,
                inputMode: inputMode,
                implementationFingerprint: implementationFingerprint
            ),
            osBand: environment.osVersion...environment.osVersion,
            deviceModelIdentifiers: [environment.modelIdentifier]
        )
    ])
}

/// A physical-device-shaped environment (the simulator never qualifies).
let testQualifiableEnvironment = ScreenshotDeviceEnvironment(
    osVersion: ScreenshotOSVersion(major: 26, minor: 0),
    modelIdentifier: "iPhoneTest1,1"
)

/// The shared runtime wired with the real Requester workflow adapter and the
/// synthetic recognizer, over whatever providers a test injects.
@MainActor
func makeRequesterTestRuntime(
    local: (any ScreenshotLocalProvider<RequesterOrderWorkflow>)?,
    external: any ScreenshotExternalProvider<RequesterOrderWorkflow>,
    qualification: ScreenshotQualificationRegistry? = nil,
    environment: ScreenshotDeviceEnvironment? = nil,
    timeout: Duration = .seconds(5),
    recognizer: any ScreenshotTextRecognizing = SyntheticTextRecognizer()
) -> ScreenshotAssistanceRuntime<RequesterOrderWorkflow> {
    ScreenshotAssistanceRuntime(
        workflow: RequesterOrderWorkflow(recognizer: recognizer),
        localProvider: local,
        externalProvider: external,
        qualification: qualification,
        environment: environment,
        localAttemptTimeout: timeout
    )
}

/// A store on the PRODUCTION Requester wiring (real Apple provider factory,
/// empty production qualification, real network-backed external provider) but
/// with the synthetic recognizer in place of Vision, over a stubbed transport.
@MainActor
func makeProductionWiredRequesterStore(
    service: ScreenshotProposalService,
    preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage()
) -> ScreenshotProposalStore {
    let runtime = ScreenshotAssistanceRuntime(
        workflow: RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer()),
        localProvider: RequesterAppleOnDeviceProviderFactory.make(),
        externalProvider: RequesterOpenAIExternalProvider(service: service)
    )
    return ScreenshotProposalStore(availability: .enabledForTesting(), service: service, preferences: preferences, runtime: runtime)
}

struct WorkflowRefusedSelection: Error {}

/// Awaits a workflow's evaluation of `selection` for an attempt and fails the
/// test (rather than trapping) if the workflow's eligibility policy refused it.
/// With no `token`, the evaluation is for a fresh attempt on the runtime's own
/// fence (which retires whatever attempt was current, as a new selection does).
@MainActor
func evaluated<W: ScreenshotWorkflow>(
    _ runtime: ScreenshotAssistanceRuntime<W>,
    _ selection: ScreenshotSelection,
    token: ScreenshotSelectionToken? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> ScreenshotAttemptEvaluation<W.Derived> {
    let token = token ?? runtime.fence.beginAttempt()
    guard let evaluation = await runtime.evaluate(selection, for: token) else {
        XCTFail("expected the workflow to admit the selection", file: file, line: line)
        throw WorkflowRefusedSelection()
    }
    return evaluation
}

/// The requester's interaction against the real store. W4-S3 consent-authority
/// revision: `analyzeScreenshot` itself now runs the local-first phase and,
/// when it falls through, the automatic external attempt under Screenshot
/// Assistance's standing consent — there is no separate tap step any more, so
/// this is a thin passthrough kept so call sites (which predate the
/// revision) do not all need renaming. Returns the outcome that would be
/// applied, or `nil` for stale/cancelled/failed/notice-only/ended work.
@MainActor
func analyzeThroughExternalFallback(
    store: ScreenshotProposalStore,
    images: [ScreenshotPreparedImage],
    participantAuthority: String?,
    token: ScreenshotSelectionToken
) async -> ScreenshotProposalOutcome? {
    await store.analyzeScreenshot(images: images, participantAuthority: { participantAuthority }, token: token)
}
