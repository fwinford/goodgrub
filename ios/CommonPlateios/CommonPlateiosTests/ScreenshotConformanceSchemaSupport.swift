//
//  ScreenshotConformanceSchemaSupport.swift
//  CommonPlateiosTests
//
// W4-S3 architecture-conformance support: a NON-SHIPPING second workflow and
// second/third providers that prove the shared runtime is not Requester-shaped.
// It exists ONLY in the test target — it is not compiled into the app, so it
// cannot be reachable in production — and every provider identity here is
// `.nonShipping`, so no production registry can qualify it.
//
// It makes no quality claim and creates no production qualification. It is
// meaningfully unlike Requester on both axes the runtime must stay neutral to:
//
// - schema/output shape: labelled items plus a total, with per-field
//   citations across screenshots — no meals, vendors, swipes, or Dining Dollars;
// - evidence strategy: admission and both providers work from the pixels (the
//   synthetic "pixel payload" in `image.data`), with NO recognized text
//   anywhere in the workflow's derived data.
//
// It deliberately imports nothing Requester: no DiningSpot, MealItem,
// ScreenshotProposal*, or Requester adapter type.
import Foundation
@testable import CommonPlateios

/// A synthetic pixel payload: newline-separated `LABEL:<text>` and
/// `TOTAL:<cents>` lines, with the first byte `0` marking a blank screenshot.
enum ConformanceScreenshot {
    static func image(_ lines: [String], blank: Bool = false) -> ScreenshotPreparedImage {
        let payload = Data(([blank ? "\u{0}" : "\u{1}"] + lines).joined(separator: "\n").utf8)
        return ScreenshotPreparedImage(sourceData: payload, data: payload, mimeType: "image/test")
    }

    static func isBlank(_ image: ScreenshotPreparedImage) -> Bool {
        image.data.first == 0
    }

    static func lines(_ image: ScreenshotPreparedImage) -> [String] {
        String(decoding: image.data.dropFirst(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// The second schema's provider output: labelled items and a total.
struct ConformanceRawOutput: Equatable {
    var labels: [String]
    var totalCents: Int?
}

/// The second schema's validated outcome.
struct ConformanceOutcome: Equatable {
    var labels: [String]
    var totalCents: Int?
}

struct ConformanceWorkflow: ScreenshotWorkflow {
    /// Workflow-owned derived data: which screenshots the pixel-only policy
    /// admitted. Deliberately not text.
    typealias Derived = [Int]
    typealias LocalRawOutput = ConformanceRawOutput
    typealias ExternalRawOutput = ConformanceRawOutput
    typealias Outcome = ConformanceOutcome

    static let identity = ScreenshotWorkflowIdentity(
        schemaID: "test.conformance.labelled-total",
        schemaVersion: 1,
        validatorVersion: 1
    )
    var identity: ScreenshotWorkflowIdentity { Self.identity }

    static let maximumLabels = 20
    /// The field key a total's citations are stored under.
    static let totalField = "total"

    /// Pixel-only eligibility: a blank screenshot is not admitted. No text is
    /// recognized or derived.
    func evaluate(_ selection: ScreenshotSelection) async -> ScreenshotWorkflowEvaluation<[Int]>? {
        let admitted = Set(selection.items.filter { !ConformanceScreenshot.isBlank($0.image) }.map(\.index))
        guard let subset = selection.retaining(admitted) else { return nil }
        return ScreenshotWorkflowEvaluation(selection: subset, derived: subset.items.map(\.index))
    }

    func validateLocal(
        _ result: ScreenshotProviderResult<ConformanceRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<[Int]>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<ConformanceOutcome> {
        validate(result, evaluation: evaluation)
    }

    func validateExternal(
        _ result: ScreenshotProviderResult<ConformanceRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<[Int]>,
        strategy: ScreenshotInputMode
    ) -> ScreenshotValidation<ConformanceOutcome> {
        validate(result, evaluation: evaluation)
    }

    /// Deterministic validation:
    /// - more than `maximumLabels` labels is invalid output;
    /// - blank labels are dropped;
    /// - a total needs validator-REQUIRED evidence: at least one citation of an
    ///   admitted screenshot under `totalField`, else it is not proposed;
    /// - citations of screenshots that were not admitted are dropped.
    private func validate(
        _ result: ScreenshotProviderResult<ConformanceRawOutput>,
        evaluation: ScreenshotWorkflowEvaluation<[Int]>
    ) -> ScreenshotValidation<ConformanceOutcome> {
        guard result.output.labels.count <= Self.maximumLabels else { return .invalid }
        let admitted = Set(evaluation.derived)

        var accepted: [String: [ScreenshotEvidenceEntry]] = [:]
        for field in result.evidence.fieldKeys {
            let kept = result.evidence.entries(for: field).filter { admitted.contains($0.screenshotIndex) }
            if !kept.isEmpty { accepted[field] = kept }
        }

        let labels = result.output.labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var total = result.output.totalCents
        if let candidate = total, !(0...1_000_000).contains(candidate) || accepted[Self.totalField] == nil {
            total = nil
        }
        if total == nil { accepted[Self.totalField] = nil }

        return .valid(
            ConformanceOutcome(labels: labels, totalCents: total),
            evidence: ScreenshotEvidenceSet(entriesByField: accepted)
        )
    }
}

/// Reads the pixels directly (direct-image strategy). Cites, for the total,
/// every admitted screenshot that shows a `TOTAL:` line — across screenshots —
/// with an optional region on the first.
@MainActor
final class ConformanceDirectImageProvider: ScreenshotLocalProvider, ScreenshotExternalProvider {
    typealias Workflow = ConformanceWorkflow

    static let localIdentity = ScreenshotProviderIdentity.nonShipping(id: "test.conformance.direct-image", strategyVersion: "1")

    var identity: ScreenshotProviderIdentity = ConformanceDirectImageProvider.localIdentity
    var inputMode: ScreenshotInputMode = .directImageMultimodal
    var availabilityValue: ScreenshotLocalAvailability = .available
    /// When `false` the provider cites nothing at all.
    var citesEvidence = true
    private(set) var callCount = 0
    private(set) var lastInput: ScreenshotProviderInput<ConformanceWorkflow>?

    func availability() -> ScreenshotLocalAvailability { availabilityValue }

    func extract(
        _ input: ScreenshotProviderInput<ConformanceWorkflow>
    ) async throws -> ScreenshotProviderResult<ConformanceRawOutput> {
        produce(input)
    }

    func analyze(
        _ input: ScreenshotProviderInput<ConformanceWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ConformanceRawOutput> {
        produce(input)
    }

    private func produce(_ input: ScreenshotProviderInput<ConformanceWorkflow>) -> ScreenshotProviderResult<ConformanceRawOutput> {
        callCount += 1
        lastInput = input
        var labels: [String] = []
        var total: Int?
        var totalCitations: [ScreenshotEvidenceEntry] = []
        var labelCitations: [String: [ScreenshotEvidenceEntry]] = [:]
        for item in input.selection.items {
            for line in ConformanceScreenshot.lines(item.image) {
                if line.hasPrefix("LABEL:") {
                    let text = String(line.dropFirst("LABEL:".count))
                    labelCitations["label.\(labels.count)"] = [
                        ScreenshotEvidenceEntry(screenshotIndex: item.index, sourceText: line)
                    ]
                    labels.append(text)
                } else if line.hasPrefix("TOTAL:"), let cents = Int(line.dropFirst("TOTAL:".count)) {
                    total = cents
                    totalCitations.append(ScreenshotEvidenceEntry(
                        screenshotIndex: item.index,
                        sourceText: line,
                        region: totalCitations.isEmpty
                            ? ScreenshotEvidenceRegion(x: 0.1, y: 0.8, width: 0.5, height: 0.1)
                            : nil
                    ))
                }
            }
        }
        var evidence: [String: [ScreenshotEvidenceEntry]] = labelCitations
        if !totalCitations.isEmpty { evidence[ConformanceWorkflow.totalField] = totalCitations }
        return ScreenshotProviderResult(
            output: ConformanceRawOutput(labels: labels, totalCents: total),
            evidence: citesEvidence ? ScreenshotEvidenceSet(entriesByField: evidence) : .empty
        )
    }
}

/// A different evidence strategy for the same schema: a layout-aware local
/// provider that does its own private preprocessing (grouping the payload's
/// lines into regions) and cites those regions.
@MainActor
final class ConformanceLayoutProvider: ScreenshotLocalProvider {
    typealias Workflow = ConformanceWorkflow

    let identity = ScreenshotProviderIdentity.nonShipping(id: "test.conformance.layout", strategyVersion: "1")
    let inputMode: ScreenshotInputMode = .ocrLayoutAware
    private(set) var callCount = 0

    func availability() -> ScreenshotLocalAvailability { .available }

    func extract(
        _ input: ScreenshotProviderInput<ConformanceWorkflow>
    ) async throws -> ScreenshotProviderResult<ConformanceRawOutput> {
        callCount += 1
        var total: Int?
        var citations: [ScreenshotEvidenceEntry] = []
        for item in input.selection.items {
            let lines = ConformanceScreenshot.lines(item.image)
            for (row, line) in lines.enumerated() where line.hasPrefix("TOTAL:") {
                total = Int(line.dropFirst("TOTAL:".count))
                // Private preprocessing: the line's row becomes a normalized band.
                let band = 1.0 / Double(max(lines.count, 1))
                citations.append(ScreenshotEvidenceEntry(
                    screenshotIndex: item.index,
                    sourceText: line,
                    region: ScreenshotEvidenceRegion(x: 0, y: band * Double(row), width: 1, height: band)
                ))
            }
        }
        return ScreenshotProviderResult(
            output: ConformanceRawOutput(labels: [], totalCents: total),
            evidence: ScreenshotEvidenceSet(entriesByField: citations.isEmpty ? [:] : [ConformanceWorkflow.totalField: citations])
        )
    }
}

/// A runtime for the second schema over the given providers.
@MainActor
func makeConformanceRuntime(
    local: (any ScreenshotLocalProvider<ConformanceWorkflow>)?,
    external: any ScreenshotExternalProvider<ConformanceWorkflow>,
    qualification: ScreenshotQualificationRegistry? = nil,
    environment: ScreenshotDeviceEnvironment = testQualifiableEnvironment
) -> ScreenshotAssistanceRuntime<ConformanceWorkflow> {
    ScreenshotAssistanceRuntime(
        workflow: ConformanceWorkflow(),
        localProvider: local,
        externalProvider: external,
        qualification: qualification,
        environment: environment,
        localAttemptTimeout: .seconds(5)
    )
}
