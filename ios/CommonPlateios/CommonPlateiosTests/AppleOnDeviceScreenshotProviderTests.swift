//
//  AppleOnDeviceScreenshotProviderTests.swift
//  CommonPlateiosTests
//
// W4-S3: the Requester Apple on-device provider's availability fencing and, when
// the environment actually provides the model, one live extraction smoke run. The
// live run uses synthetic OCR text, sends nothing off-device, and asserts only
// that the real model's structured output is acceptable to the on-device
// validator — it is NOT qualification evidence (simulator/unit proof never
// qualifies an Apple path) and is skipped, with a stated reason, where the
// model is unavailable. The Apple OCR → flattened text → Foundation Models
// candidate remains NOT QUALIFIED.
import XCTest
@testable import CommonPlateios

@MainActor
final class AppleOnDeviceScreenshotProviderTests: XCTestCase {
    func testFactoryProvidesTheProviderOnlyWhereTheFrameworkCanRun() {
        let provider = RequesterAppleOnDeviceProviderFactory.make()
        if #available(iOS 26.0, *) {
            XCTAssertNotNil(provider)
        } else {
            XCTAssertNil(provider, "the iOS 17.6 deployment target must never reach Foundation Models")
        }
    }

    func testCandidateDeclaresItsEvidenceStrategyAndIdentity() throws {
        let provider = try XCTUnwrap(RequesterAppleOnDeviceProviderFactory.make(), "needs a Foundation Models runtime")
        XCTAssertEqual(provider.inputMode, .ocrFlattenedText)
        XCTAssertTrue(provider.inputMode.consumesRuntimeOCREvidence)
        XCTAssertFalse(RequesterOrderPolicy.permitsDiningDollarsEstimate(for: provider.inputMode))
        XCTAssertEqual(provider.identity.id, "apple.foundation-models")
        XCTAssertEqual(provider.identity.distribution, .shipping)
    }

    /// Runtime availability is reported without deciding qualification, and the
    /// production registry keeps every combination unqualified regardless.
    func testProductionCapabilityIsAlwaysNotQualifiedWhateverTheModelReports() {
        let runtime = ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(),
            localProvider: RequesterAppleOnDeviceProviderFactory.make(),
            externalProvider: StubExternalProvider()
        )
        let capability = runtime.localCapability()
        XCTAssertEqual(capability.qualification, .notQualified)
        XCTAssertFalse(capability.permitsLocalAttempt)
    }

    /// Availability alone never invokes Foundation Models: on production wiring
    /// (empty registry) a whole attempt makes no local provider call, whatever
    /// the model reports.
    func testFoundationModelsAvailabilityAloneNeverInvokesTheProviderOnProductionWiring() async throws {
        let runtime = ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer()),
            localProvider: RequesterAppleOnDeviceProviderFactory.make(),
            externalProvider: StubExternalProvider()
        )
        let selection = try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input()]))
        let evaluation = try await evaluated(runtime, selection)
        let result = await runtime.runLocal(evaluation)

        guard case .localUnavailable = result else {
            return XCTFail("nothing may run locally while no combination is qualified: \(result)")
        }
    }

    func testLiveOnDeviceExtractionProducesValidatorAcceptableOutput() async throws {
        guard let provider = RequesterAppleOnDeviceProviderFactory.make() else {
            throw XCTSkip("Foundation Models is not available at this OS version")
        }
        guard provider.availability() == .available else {
            throw XCTSkip("Apple on-device model unavailable in this environment: \(provider.availability())")
        }

        // Qualify exactly this (simulator-shaped) environment for this one run
        // via an injected registry — production stays closed.
        let environment = testQualifiableEnvironment
        let runtime = makeRequesterTestRuntime(
            local: provider,
            external: StubExternalProvider(),
            qualification: qualifiedRegistry(
                provider: provider.identity,
                inputMode: provider.inputMode,
                environment: environment
            ),
            environment: environment,
            timeout: .seconds(90)
        )
        let text = "Your Pickup Order\nJasper Kane Cafe\n1 Create Your Own Bowl\nChicken\nNo Side\n1M\nContinue to Checkout"
        let selection = try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input(text)]))
        let evaluation = try await evaluated(runtime, selection)
        let result = await runtime.runLocal(evaluation)

        switch result {
        case .completed(let analysis):
            XCTAssertTrue(analysis.outcome.eligible)
            // Whatever the model produced already passed the validator; the
            // OCR→flattened-text strategy can never carry a Dining Dollars estimate.
            XCTAssertNil(analysis.outcome.proposal.estimatedDiningDollarsCents)
        case .failed(let error):
            XCTFail("the live model attempt failed: \(error)")
        case .localUnavailable(let reason):
            XCTFail("the model reported available but the attempt was unavailable: \(String(describing: reason))")
        case .cancelled:
            XCTFail("unexpected cancellation")
        }
    }
}
