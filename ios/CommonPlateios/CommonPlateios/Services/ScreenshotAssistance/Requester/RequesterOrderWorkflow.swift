//
//  RequesterOrderWorkflow.swift
//  CommonPlateios
//
// W4-S3 Requester adapter: the `requester.order` workflow for the shared
// Screenshot Assistance runtime. Everything Requester-specific lives here and in
// its sibling files — Grubhub eligibility, catalog vendor grounding, Meal
// Exchange / Dining Dollars rules, the meal-shaped raw output, the on-device
// validator, and external-result validation. The shared runtime knows none of
// it; it sees only this type through `ScreenshotWorkflow`.
import Foundation

/// Requester policy: what each evidence strategy is allowed to propose. This is
/// deliberately NOT in the shared runtime — the runtime states only the
/// workflow-neutral fact of whether a strategy reads the same runtime OCR that
/// corroborates it.
enum RequesterOrderPolicy {
    /// The order-level Dining Dollars estimate may only be proposed by a
    /// strategy that is independent of the runtime Vision OCR that corroborates
    /// it (a direct-image mode, after its own qualification). A provider that
    /// reads that same OCR text cannot corroborate itself.
    static func permitsDiningDollarsEstimate(for strategy: ScreenshotInputMode) -> Bool {
        !strategy.consumesRuntimeOCREvidence
    }
}

/// The Requester workflow's derived evidence for one attempt: the on-device
/// Vision OCR text of exactly the screenshots its eligibility policy admitted.
/// This is the independent evidence deterministic corroboration reads — never
/// anything a provider returned.
struct RequesterOrderEvidence {
    /// Recognized text keyed by ORIGINAL selection index.
    let textsByIndex: [Int: String]
    /// Minimal relation evidence keyed by the same ORIGINAL selection index.
    /// Raw Vision boxes have already been discarded.
    let totalGeometryByIndex: [Int: ScreenshotTotalGeometryEvidence]
    /// The admitted screenshots' text joined with newlines in selection order.
    let combinedText: String

    func text(at index: Int) -> String {
        textsByIndex[index] ?? ""
    }

    func totalGeometry(at index: Int) -> ScreenshotTotalGeometryEvidence? {
        totalGeometryByIndex[index]
    }

    /// The text of each item of `selection`, in selection order.
    func orderedTexts(for selection: ScreenshotSelection) -> [String] {
        selection.items.map { text(at: $0.index) }
    }

    func orderedTotalGeometry(for selection: ScreenshotSelection) -> [ScreenshotTotalGeometryEvidence?] {
        selection.items.map { totalGeometry(at: $0.index) }
    }
}

struct RequesterOrderWorkflow: ScreenshotWorkflow {
    typealias Derived = RequesterOrderEvidence
    typealias LocalRawOutput = RequesterOrderRawOutput
    /// The backend route returns an already-shaped proposal outcome; it is
    /// still re-validated on device before it can become applyable.
    typealias ExternalRawOutput = ScreenshotProposalOutcome
    typealias Outcome = ScreenshotProposalOutcome

    /// `validatorVersion` is a human-readable diagnostic label for
    /// `RequesterOrderOutputValidator`, `RequesterOrderExternalOutcomeValidator`,
    /// and the deterministic evidence rules they share with
    /// `src/screenshotProposalValidation.ts`. Qualification does not depend on
    /// anyone bumping it: any change to those files changes the build-derived
    /// `ScreenshotQualificationFingerprint`.
    static let identity = ScreenshotWorkflowIdentity(
        schemaID: "requester.order",
        schemaVersion: 1,
        validatorVersion: 1
    )

    var identity: ScreenshotWorkflowIdentity { Self.identity }

    private let recognizer: any ScreenshotTextRecognizing
    private let vendors: [DiningSpot]

    /// `nil` recognizer/vendors resolve to the production values inside the
    /// initializer (default-argument expressions are not main-actor isolated,
    /// and these production values are).
    init(recognizer: (any ScreenshotTextRecognizing)? = nil, vendors: [DiningSpot]? = nil) {
        self.recognizer = recognizer ?? VisionScreenshotTextRecognizer()
        self.vendors = vendors ?? SupportedVendorCatalog.diningSpots
    }

    // MARK: - Eligibility (deterministic, on-device, provider-independent)

    /// Recognizes each screenshot of the ordered selection and keeps those that
    /// pass the accepted Requester eligibility rule, evaluated from on-device
    /// OCR text only. `nil` means the whole selection is policy-ineligible: no
    /// provider of either class may be invoked and no external-AI offer may be
    /// made for it. An ineligible screenshot contributes neither bytes nor
    /// evidence to any provider.
    func evaluate(_ selection: ScreenshotSelection) async -> ScreenshotWorkflowEvaluation<RequesterOrderEvidence>? {
        var eligibleIndices: Set<Int> = []
        var textsByIndex: [Int: String] = [:]
        var totalGeometryByIndex: [Int: ScreenshotTotalGeometryEvidence] = [:]
        var eligibleTexts: [String] = []
        for item in selection.items {
            let recognized = await recognizer.recognize(in: item.image)
            let text = recognized.text
            // A retired attempt stops recognizing the rest of its selection.
            if Task.isCancelled { return nil }
            guard RequesterOrderDeterministicEvidence.evaluateEligibility(text).eligible else { continue }
            eligibleIndices.insert(item.index)
            textsByIndex[item.index] = text
            totalGeometryByIndex[item.index] = recognized.totalGeometryEvidence
            eligibleTexts.append(text)
        }
        guard let eligible = selection.retaining(eligibleIndices) else { return nil }
        return ScreenshotWorkflowEvaluation(
            selection: eligible,
            derived: RequesterOrderEvidence(
                textsByIndex: textsByIndex,
                totalGeometryByIndex: totalGeometryByIndex,
                combinedText: eligibleTexts.joined(separator: "\n")
            )
        )
    }

    // MARK: - Validation

    func validateLocal(
        _ result: ScreenshotProviderResult<RequesterOrderRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<ScreenshotProposalOutcome> {
        switch RequesterOrderOutputValidator.validate(
            raw: result.output.jsonObject,
            evidenceText: evaluation.derived.combinedText,
            evidenceImageCount: evaluation.selection.count,
            imageEvidenceTexts: evaluation.derived.orderedTexts(for: evaluation.selection),
            imageTotalGeometryEvidence: evaluation.derived.orderedTotalGeometry(for: evaluation.selection),
            allowsDiningDollarsEstimate: RequesterOrderPolicy.permitsDiningDollarsEstimate(for: strategy),
            vendors: vendors
        ) {
        case .valid(let proposal):
            // Requester does not accept provider-cited evidence: no Requester
            // UI displays it and no Requester rule validates it, so none is
            // forwarded.
            return .valid(ScreenshotProposalOutcome(eligible: true, proposal: proposal), evidence: .empty)
        case .invalid:
            return .invalid
        }
    }

    func validateExternal(
        _ result: ScreenshotProviderResult<ScreenshotProposalOutcome>,
        evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<ScreenshotProposalOutcome> {
        .valid(
            RequesterOrderExternalOutcomeValidator.validate(
                result.output,
                evidenceText: evaluation.derived.combinedText,
                imageEvidenceTexts: evaluation.derived.orderedTexts(for: evaluation.selection),
                imageTotalGeometryEvidence: evaluation.derived.orderedTotalGeometry(for: evaluation.selection),
                allowsDiningDollarsEstimate: RequesterOrderPolicy.permitsDiningDollarsEstimate(for: strategy),
                vendors: vendors
            ),
            evidence: .empty
        )
    }
}
