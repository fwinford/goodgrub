//
//  ScreenshotSharedRuntimeConformanceTests.swift
//  CommonPlateiosTests
//
// W4-S3 architecture conformance: the shared runtime supports a SECOND schema
// and a different evidence/input strategy with no Requester code involved. The
// second workflow and its providers are test-target-only, `.nonShipping`, make
// no quality claim, and create no production qualification.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotSharedRuntimeConformanceTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    private func registry(
        provider: ScreenshotProviderIdentity,
        mode: ScreenshotInputMode
    ) -> ScreenshotQualificationRegistry {
        qualifiedRegistry(provider: provider, inputMode: mode, workflow: ConformanceWorkflow.identity, environment: environment)
    }

    private func selection(_ images: [ScreenshotPreparedImage]) throws -> ScreenshotSelection {
        try XCTUnwrap(ScreenshotSelection(images: images))
    }

    private var threeScreenshots: [ScreenshotPreparedImage] {
        [
            ConformanceScreenshot.image(["LABEL:Alpha", "LABEL:Beta"]),
            ConformanceScreenshot.image(["LABEL:Gamma", "TOTAL:1250"]),
            ConformanceScreenshot.image(["TOTAL:1250"]),
        ]
    }

    // MARK: - The same runtime runs a second schema end to end

    func testSecondSchemaRunsThroughTheSharedRuntimeEndToEnd() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
        let result = await runtime.runLocal(evaluation)

        guard case .completed(let analysis) = result else { return XCTFail("expected a completed attempt: \(result)") }
        XCTAssertEqual(analysis.outcome, ConformanceOutcome(labels: ["Alpha", "Beta", "Gamma"], totalCents: 1250))
        XCTAssertEqual(provider.callCount, 1, "one logical attempt for the whole selection")
    }

    func testSecondSchemaHasNoRequesterDependency() throws {
        let support = try source("ios/CommonPlateios/CommonPlateiosTests/ScreenshotConformanceSchemaSupport.swift")
        let code = ScreenshotBoundarySource.codeLines(support)
        for token in [
            "Requester", "DiningSpot", "MealItem", "ScreenshotProposal", "SupportedVendorCatalog",
            "RequesterOrder", "ScreenshotTextRecognizing", "recognizeText", "localEvidenceText",
        ] {
            XCTAssertFalse(code.contains(token), "the second schema must not touch `\(token)`")
        }
    }

    // MARK: - Provider input is the ordered selection, whatever the strategy

    func testProviderReceivesTheOrderedAdmittedSelectionWithOriginalIndices() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let images = [
            ConformanceScreenshot.image(["LABEL:One"]),
            ConformanceScreenshot.image(["LABEL:Blank"], blank: true),
            ConformanceScreenshot.image(["LABEL:Three"]),
            ConformanceScreenshot.image(["LABEL:Four"]),
        ]
        let evaluation = try await evaluated(runtime, try selection(images))
        XCTAssertEqual(evaluation.derived, [0, 2, 3])

        _ = await runtime.runLocal(evaluation)

        XCTAssertEqual(provider.lastInput?.selection.items.map(\.index), [0, 2, 3], "order and original indices preserved")
        XCTAssertEqual(provider.lastInput?.selection.count, 3)
    }

    func testAWhollyIneligibleSelectionReachesNoProvider() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(local: provider, external: provider)
        let none = await runtime.evaluate(try selection([ConformanceScreenshot.image(["x"], blank: true)]), for: runtime.fence.beginAttempt())
        XCTAssertNil(none)
        XCTAssertEqual(provider.callCount, 0)
    }

    // MARK: - Optional, multi-screenshot, ephemeral evidence

    func testEvidenceCitesMultipleScreenshotsForOneFieldWithAnOptionalRegion() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
        guard case .completed(let analysis) = await runtime.runLocal(evaluation) else { return XCTFail("expected completed") }

        let total = analysis.evidence.entries(for: ConformanceWorkflow.totalField)
        XCTAssertEqual(total.map(\.screenshotIndex), [1, 2], "one field cites two screenshots, in order")
        XCTAssertEqual(total.map(\.sourceText), ["TOTAL:1250", "TOTAL:1250"])
        XCTAssertNotNil(total[0].region, "a citation may carry a normalized region")
        XCTAssertNil(total[1].region, "the region is optional")
        XCTAssertEqual(analysis.evidence.entries(for: "label.0").map(\.screenshotIndex), [0])
    }

    /// A provider may omit evidence unless the schema's validator requires it;
    /// this schema's validator requires it for the total only.
    func testEvidenceIsOptionalUnlessTheValidatorRequiresIt() async throws {
        let provider = ConformanceDirectImageProvider()
        provider.citesEvidence = false
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
        guard case .completed(let analysis) = await runtime.runLocal(evaluation) else { return XCTFail("expected completed") }

        XCTAssertEqual(analysis.outcome.labels, ["Alpha", "Beta", "Gamma"], "uncited labels are still valid")
        XCTAssertNil(analysis.outcome.totalCents, "the total needs its validator-required evidence")
        XCTAssertTrue(analysis.evidence.isEmpty)
    }

    func testValidatorDropsCitationsOfScreenshotsThatWereNotAdmitted() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        // Screenshot 1 is blank, so the policy never admits it.
        let images = [
            ConformanceScreenshot.image(["LABEL:Only"]),
            ConformanceScreenshot.image(["TOTAL:9"], blank: true),
        ]
        let evaluation = try await evaluated(runtime, try selection(images))
        let forged = ScreenshotProviderResult(
            output: ConformanceRawOutput(labels: ["Only"], totalCents: 9),
            evidence: ScreenshotEvidenceSet(entriesByField: [
                ConformanceWorkflow.totalField: [ScreenshotEvidenceEntry(screenshotIndex: 1, sourceText: "TOTAL:9")],
                "label.0": [ScreenshotEvidenceEntry(screenshotIndex: 0, sourceText: "LABEL:Only")],
            ])
        )

        guard case .valid(let outcome, let evidence) = ConformanceWorkflow().validateLocal(
            forged,
            evaluation: ScreenshotWorkflowEvaluation(selection: evaluation.selection, derived: evaluation.derived),
            strategy: .directImageMultimodal
        ) else { return XCTFail("expected valid") }

        XCTAssertNil(outcome.totalCents, "its only citation was of a screenshot the policy did not admit")
        XCTAssertEqual(evidence.fieldKeys, ["label.0"])
    }

    func testEvidenceRegionsMustBeRealNormalizedBoxes() {
        XCTAssertNotNil(ScreenshotEvidenceRegion(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNotNil(ScreenshotEvidenceRegion(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertNil(ScreenshotEvidenceRegion(x: -0.1, y: 0, width: 0.5, height: 0.5))
        XCTAssertNil(ScreenshotEvidenceRegion(x: 0.6, y: 0, width: 0.5, height: 0.5), "extends past the right edge")
        XCTAssertNil(ScreenshotEvidenceRegion(x: 0, y: 0.6, width: 0.5, height: 0.5), "extends past the bottom edge")
        XCTAssertNil(ScreenshotEvidenceRegion(x: 0, y: 0, width: 0, height: 0.5), "no area")
        XCTAssertNil(ScreenshotEvidenceRegion(x: .nan, y: 0, width: 0.5, height: 0.5))
        XCTAssertNil(ScreenshotEvidenceRegion(x: 0, y: 0, width: .infinity, height: 0.5))
    }

    /// Evidence belongs to the attempt that produced it: the runtime hands it
    /// back and keeps nothing, so a later attempt can never inherit it.
    func testEvidenceIsReleasedWithTheAttemptAndNeverCarriedToTheNext() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let first = try await evaluated(runtime, try selection(threeScreenshots))
        guard case .completed(let firstAnalysis) = await runtime.runLocal(first) else { return XCTFail("expected completed") }
        XCTAssertFalse(firstAnalysis.evidence.isEmpty)

        provider.citesEvidence = false
        let second = try await evaluated(runtime, try selection([ConformanceScreenshot.image(["LABEL:Solo"])]))
        guard case .completed(let secondAnalysis) = await runtime.runLocal(second) else { return XCTFail("expected completed") }

        XCTAssertTrue(secondAnalysis.evidence.isEmpty, "nothing from the first attempt survives into the second")
        XCTAssertEqual(secondAnalysis.outcome.labels, ["Solo"])
    }

    func testEvidenceRepresentationCannotBeSerializedOrPersisted() throws {
        let evidence = ScreenshotBoundarySource.codeLines(
            try source("ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance/ScreenshotEvidence.swift")
        )
        for token in ["Codable", "Encodable", "Decodable", "NSCoding", "NSSecureCoding", "UserDefaults", "FileManager"] {
            XCTAssertFalse(evidence.contains(token), "evidence is memory-only and must not gain `\(token)`")
        }
    }

    // MARK: - A different evidence strategy for the same schema

    func testASecondEvidenceStrategyRunsUnderItsOwnQualificationWithPrivatePreprocessing() async throws {
        let layout = ConformanceLayoutProvider()
        let direct = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: layout,
            external: direct,
            qualification: registry(provider: layout.identity, mode: .ocrLayoutAware)
        )
        let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
        guard case .completed(let analysis) = await runtime.runLocal(evaluation) else { return XCTFail("expected completed") }

        XCTAssertEqual(analysis.outcome.totalCents, 1250)
        let regions = analysis.evidence.entries(for: ConformanceWorkflow.totalField).compactMap(\.region)
        XCTAssertEqual(regions.count, 2, "the layout provider's private preprocessing produced regions")
        XCTAssertEqual(layout.callCount, 1)
        XCTAssertEqual(direct.callCount, 0)
    }

    // MARK: - Qualification is per workflow, provider, and strategy

    func testSecondSchemaIsNotQualifiedByARequesterQualificationAndViceVersa() async throws {
        let provider = ConformanceDirectImageProvider()
        // A registry that only qualifies the REQUESTER workflow.
        let requesterOnly = qualifiedRegistry(
            provider: provider.identity,
            inputMode: .directImageMultimodal,
            workflow: RequesterOrderWorkflow.identity,
            environment: environment
        )
        let conformanceRuntime = makeConformanceRuntime(local: provider, external: provider, qualification: requesterOnly)
        let evaluation = try await evaluated(conformanceRuntime, try selection(threeScreenshots))
        guard case .localUnavailable = await conformanceRuntime.runLocal(evaluation) else {
            return XCTFail("a Requester qualification must not qualify another schema")
        }
        XCTAssertEqual(provider.callCount, 0)

        // And the second schema's qualification does not qualify Requester.
        let stub = StubLocalProvider(inputMode: .directImageMultimodal, behavior: .output(RequesterOrderRawOutput(
            visibleVenueText: nil, foodItems: [], mealSwipes: nil
        )))
        let secondOnly = registry(provider: StubLocalProvider.stubIdentity, mode: .directImageMultimodal)
        let requesterRuntime = makeRequesterTestRuntime(
            local: stub, external: StubExternalProvider(), qualification: secondOnly, environment: environment
        )
        let requesterEvaluation = try await evaluated(
            requesterRuntime,
            try selection([ScreenshotTestEvidence.input()])
        )
        guard case .localUnavailable = await requesterRuntime.runLocal(requesterEvaluation) else {
            return XCTFail("the second schema's qualification must not qualify Requester")
        }
        XCTAssertEqual(stub.extractCallCount, 0)
    }

    func testSecondSchemaStrategyValidatorAndProviderVersionsAreEachRequired() async throws {
        let provider = ConformanceDirectImageProvider()
        let workflow = ConformanceWorkflow.identity
        let cases: [(String, ScreenshotQualificationRegistry)] = [
            ("another strategy", registry(provider: provider.identity, mode: .ocrLayoutAware)),
            ("another validator version", qualifiedRegistry(
                provider: provider.identity, inputMode: .directImageMultimodal,
                workflow: ScreenshotWorkflowIdentity(
                    schemaID: workflow.schemaID, schemaVersion: workflow.schemaVersion, validatorVersion: workflow.validatorVersion + 1
                ),
                environment: environment
            )),
            ("another provider strategy version", registry(
                provider: .nonShipping(id: provider.identity.id, strategyVersion: "2"), mode: .directImageMultimodal
            )),
        ]
        for (name, qualification) in cases {
            let runtime = makeConformanceRuntime(local: provider, external: provider, qualification: qualification)
            let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
            guard case .localUnavailable = await runtime.runLocal(evaluation) else { return XCTFail("\(name) must not qualify") }
        }
        XCTAssertEqual(provider.callCount, 0)
    }

    // MARK: - Cannot ship

    func testConformanceProvidersCannotBeQualifiedIntoProductionOrRunOnProductionWiring() async throws {
        let direct = ConformanceDirectImageProvider()
        let layout = ConformanceLayoutProvider()
        XCTAssertEqual(direct.identity.distribution, .nonShipping)
        XCTAssertEqual(layout.identity.distribution, .nonShipping)

        // Even a hand-built entry naming them is dropped by the shipping constructor.
        let entries = [
            ScreenshotQualificationEntry(
                key: ScreenshotQualificationKey(workflow: ConformanceWorkflow.identity, provider: direct.identity, inputMode: .directImageMultimodal, implementationFingerprint: ScreenshotQualificationFingerprint.current),
                osBand: environment.osVersion...environment.osVersion,
                deviceModelIdentifiers: [environment.modelIdentifier]
            ),
            ScreenshotQualificationEntry(
                key: ScreenshotQualificationKey(workflow: ConformanceWorkflow.identity, provider: layout.identity, inputMode: .ocrLayoutAware, implementationFingerprint: ScreenshotQualificationFingerprint.current),
                osBand: environment.osVersion...environment.osVersion,
                deviceModelIdentifiers: [environment.modelIdentifier]
            ),
        ]
        let shipped = ScreenshotQualificationRegistry(shippingEntries: entries)
        XCTAssertTrue(shipped.entries.isEmpty)

        // On the production registry they never run.
        for qualification in [shipped, ScreenshotQualificationRegistry.production] {
            let runtime = makeConformanceRuntime(local: direct, external: direct, qualification: qualification)
            let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
            guard case .localUnavailable = await runtime.runLocal(evaluation) else { return XCTFail("must not run") }
        }
        XCTAssertEqual(direct.callCount, 0)
        XCTAssertEqual(layout.callCount, 0)
        XCTAssertTrue(ScreenshotQualificationRegistry.production.entries.isEmpty)
    }

    // MARK: - External path of the second schema

    func testSecondSchemaExternalPathNeedsItsPermissionAndIsRevalidated() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(local: nil, external: provider)
        let evaluation = try await evaluated(runtime, try selection(threeScreenshots))
        let permission = try XCTUnwrap(runtime.authorizeExternalTransfer(for: evaluation.token, evaluation: evaluation))

        let analysis = try await runtime.runExternal(authority: { "opaque" }, permission: permission)
        XCTAssertEqual(analysis.outcome.totalCents, 1250)
        XCTAssertEqual(provider.callCount, 1)

        do {
            _ = try await runtime.runExternal(authority: { "opaque" }, permission: permission)
            XCTFail("a consumed permission must not authorize a second transfer")
        } catch ScreenshotAnalysisFailure.permissionUnavailable {
            XCTAssertEqual(provider.callCount, 1)
        }
    }

    func testSecondSchemaInvalidProviderOutputIsAFailureNotAnEmptyResult() async throws {
        let provider = ConformanceDirectImageProvider()
        let runtime = makeConformanceRuntime(
            local: provider,
            external: provider,
            qualification: registry(provider: provider.identity, mode: .directImageMultimodal)
        )
        let lines = (0..<(ConformanceWorkflow.maximumLabels + 1)).map { "LABEL:l\($0)" }
        let evaluation = try await evaluated(runtime, try selection([ConformanceScreenshot.image(lines)]))
        guard case .failed(let error) = await runtime.runLocal(evaluation),
              case ScreenshotAnalysisFailure.invalidProviderOutput = error else {
            return XCTFail("the schema's validator refuses too many labels")
        }
    }

    // MARK: - Helpers

    private func source(_ relativePath: String) throws -> String {
        try ScreenshotBoundarySource.read(relativePath, from: #filePath)
    }
}
