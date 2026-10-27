//
//  ScreenshotWorkflow.swift
//  CommonPlateios
//
// W4-S3: the workflow/schema adapter contract. The shared runtime is generic
// over it and knows nothing about any workflow's fields. Everything that is
// schema-specific — eligibility policy, deterministic evidence derivation, the
// raw provider output shapes, the validator, and what "valid" produces — lives
// in the adapter that conforms here, supplied separately per workflow. There is
// deliberately no combined Requester+Helper policy object.
import Foundation

/// What an adapter derived from the ordered selection, once, for one attempt.
struct ScreenshotWorkflowEvaluation<Derived> {
    /// The screenshots the workflow's eligibility policy admitted, in selection
    /// order, each still carrying its original index.
    let selection: ScreenshotSelection
    /// Workflow-owned derived data (for example recognized text). Opaque to the
    /// runtime; handed to providers whose declared input mode consumes it, and
    /// to the workflow's own validator.
    let derived: Derived
}

/// The workflow validator's verdict on one provider output.
enum ScreenshotValidation<Outcome> {
    /// The output passed the workflow's deterministic validator. `evidence` is
    /// whatever provenance the validator itself accepted; it may be empty.
    case valid(Outcome, evidence: ScreenshotEvidenceSet)
    case invalid
}

/// One workflow's schema, eligibility policy, and deterministic validator.
protocol ScreenshotWorkflow {
    /// Workflow-owned data derived from the selection (see
    /// `ScreenshotWorkflowEvaluation.derived`).
    associatedtype Derived
    /// The schema-specific output a LOCAL provider returns, before validation.
    associatedtype LocalRawOutput
    /// The schema-specific output an EXTERNAL provider returns, before
    /// validation. May be the same type as `LocalRawOutput`.
    associatedtype ExternalRawOutput
    /// The validated, applyable result. May be empty; how "empty" routes is the
    /// consuming workflow's policy, not the runtime's.
    associatedtype Outcome

    /// Schema id/version and validator version; part of every qualification key.
    var identity: ScreenshotWorkflowIdentity { get }

    /// The workflow's deterministic, on-device eligibility policy plus whatever
    /// it derives from the selection's pixels. `nil` means the whole selection
    /// is ineligible: no provider of either class may be invoked for it.
    func evaluate(_ selection: ScreenshotSelection) async -> ScreenshotWorkflowEvaluation<Derived>?

    /// Raw local output is never authority by itself. `strategy` is the
    /// provider's declared evidence/input mode, so a workflow can decide which
    /// of its own rules are valid for that derivation.
    func validateLocal(
        _ result: ScreenshotProviderResult<LocalRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<Derived>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<Outcome>

    /// An external provider's result is re-validated on device before it can
    /// become applyable.
    func validateExternal(
        _ result: ScreenshotProviderResult<ExternalRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<Derived>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<Outcome>
}
