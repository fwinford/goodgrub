//
//  RequesterOpenAIExternalProvider.swift
//  CommonPlateios
//
// W4-S3 Requester adapter: the external-AI provider for the `requester.order`
// workflow — the existing backend route that calls OpenAI
// (`ScreenshotProposalService`) behind CommonPlate's provider abstraction.
// Reachable only through `ScreenshotAssistanceRuntime.runExternal`, which
// requires the requester's per-attempt `Use external AI` permission.
//
// Input mode (`.directImageMultimodal`): the model receives the normalized
// images; the per-image Vision OCR text sent alongside is the backend's
// independent eligibility/corroboration evidence, not the model's input.
import Foundation

struct RequesterOpenAIExternalProvider: ScreenshotExternalProvider {
    typealias Workflow = RequesterOrderWorkflow

    let service: ScreenshotProposalService

    /// `strategyVersion` is a human-readable diagnostic label for the backend
    /// route's provider strategy. Qualification does not depend on anyone
    /// bumping it: a change to this implementation changes the build-derived
    /// `ScreenshotQualificationFingerprint`.
    var identity: ScreenshotProviderIdentity {
        .shipping(id: "openai.commonplate-screenshot-proposal", strategyVersion: "backend-route-1")
    }

    var inputMode: ScreenshotInputMode { .directImageMultimodal }

    func analyze(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ScreenshotProposalOutcome> {
        let images = input.selection.items.map { item in
            ScreenshotProposalImage(
                data: item.image.data,
                mimeType: item.image.mimeType,
                localEvidenceText: input.derived.text(at: item.index),
                localTotalGeometry: input.derived.totalGeometry(at: item.index)
            )
        }
        let outcome = try await service.requestProposal(
            images: images,
            authority: authority
        )
        return ScreenshotProviderResult(output: outcome)
    }
}

/// Production wiring of the Requester workflow: the one place the shipped
/// Requester adapters are assembled. Local qualification is the empty
/// production registry, so the Apple provider is never invoked; external AI is
/// reachable only through the per-attempt permission.
enum RequesterScreenshotAssistanceProduction {
    @MainActor
    static func makeRuntime(service: ScreenshotProposalService) -> ScreenshotAssistanceRuntime<RequesterOrderWorkflow> {
        ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(),
            localProvider: RequesterAppleOnDeviceProviderFactory.make(),
            externalProvider: RequesterOpenAIExternalProvider(service: service)
        )
    }
}
