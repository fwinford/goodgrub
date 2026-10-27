//
//  ScreenshotProviders.swift
//  CommonPlateios
//
// W4-S3: the provider adapter contracts and provider-neutral results. A
// provider receives the complete ORDERED selection plus its workflow's derived
// data; its own preprocessing (recognized text, layout, regions, direct pixels,
// or a hybrid) is private to the adapter and is declared only as an input mode.
// Workflow code never changes when a provider's derivation does.
import Foundation

/// What a provider is handed for one attempt. Content-bearing, in-memory only.
struct ScreenshotProviderInput<Workflow: ScreenshotWorkflow> {
    /// The workflow-admitted screenshots, complete and in selection order. A
    /// provider may reason across all of them jointly.
    let selection: ScreenshotSelection
    /// Workflow-owned derived data. A provider whose input mode does not
    /// consume it (for example direct pixels) simply ignores it.
    let derived: Workflow.Derived
}

/// A provider's raw output plus any evidence it chose to cite. Nothing here has
/// been validated.
struct ScreenshotProviderResult<Output> {
    let output: Output
    let evidence: ScreenshotEvidenceSet

    init(output: Output, evidence: ScreenshotEvidenceSet = .empty) {
        self.output = output
        self.evidence = evidence
    }
}

/// The verifiable identity every provider path exposes, local or external.
protocol ScreenshotProviderDescriptor {
    var identity: ScreenshotProviderIdentity { get }
    /// The evidence-derivation class of this path. Part of qualification
    /// identity; may affect which of a workflow's rules are valid.
    var inputMode: ScreenshotInputMode { get }
}

/// A local provider for one workflow. Never touches the network.
protocol ScreenshotLocalProvider<Workflow>: ScreenshotProviderDescriptor {
    associatedtype Workflow: ScreenshotWorkflow
    /// Runtime availability only — never qualification.
    func availability() -> ScreenshotLocalAvailability
    /// Returns unvalidated output. The runtime, through the workflow's
    /// validator, decides whether it can become applyable.
    func extract(
        _ input: ScreenshotProviderInput<Workflow>
    ) async throws -> ScreenshotProviderResult<Workflow.LocalRawOutput>
}

/// An external provider for one workflow. Reachable only through
/// `ScreenshotAssistanceRuntime.runExternal`, which requires a per-attempt
/// transfer permission.
protocol ScreenshotExternalProvider<Workflow>: ScreenshotProviderDescriptor {
    associatedtype Workflow: ScreenshotWorkflow
    /// `authority` is an opaque credential the runtime passes through and never
    /// interprets.
    func analyze(
        _ input: ScreenshotProviderInput<Workflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<Workflow.ExternalRawOutput>
}

// MARK: - Provider-neutral results

enum ScreenshotAnalysisFailure: Error {
    case timedOut
    case invalidProviderOutput
    case permissionUnavailable
    /// Participant authority no longer existed at the moment an external
    /// transfer was about to begin. Nothing was sent.
    case authorityUnavailable
    case provider(Error)
}

/// A workflow-validated result and the evidence its validator accepted. The
/// evidence is released with the attempt: this value is handed to the consumer
/// and the runtime keeps nothing.
struct ScreenshotValidatedAnalysis<Outcome> {
    let outcome: Outcome
    let evidence: ScreenshotEvidenceSet
}

/// Provider-neutral outcome of one attempt.
enum ScreenshotAnalysisAttemptResult<Outcome> {
    /// The attempt completed and its output passed the workflow's validator.
    /// The outcome may still be empty.
    case completed(ScreenshotValidatedAnalysis<Outcome>)
    /// A local attempt could not be made: the model is unavailable, or the
    /// combination is not qualified.
    case localUnavailable(ScreenshotLocalUnavailableReason?)
    case failed(Error)
    case cancelled
}
