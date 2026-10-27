//
//  ScreenshotAssistanceRuntimeTests.swift
//  CommonPlateiosTests
//
// W4-S3 shared runtime proof, exercised through the Requester adapter: local
// capability versus qualification, the fail-closed qualification key, the
// injected-qualified local path, on-device validation of both provider classes,
// the Requester workflow's deterministic eligibility gate, ordered-selection
// preservation, bounded local context, and the single-use external-transfer
// permission — with no store, view, or transport involved. The second-schema
// (schema-neutrality) proof is `ScreenshotSharedRuntimeConformanceTests`.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotAssistanceRuntimeTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    private func makeRuntime(
        local: (any ScreenshotLocalProvider<RequesterOrderWorkflow>)?,
        external providedExternal: (any ScreenshotExternalProvider<RequesterOrderWorkflow>)? = nil,
        qualification: ScreenshotQualificationRegistry? = nil,
        timeout: Duration = .seconds(5)
    ) -> ScreenshotAssistanceRuntime<RequesterOrderWorkflow> {
        makeRequesterTestRuntime(
            local: local,
            external: providedExternal ?? StubExternalProvider(),
            qualification: qualification ?? qualifiedRegistry(environment: environment),
            environment: environment,
            timeout: timeout
        )
    }

    /// The Requester workflow's evaluation of synthetic screenshots (each text
    /// is one screenshot, in order). Only eligible screenshots survive it.
    private func evaluation(
        _ texts: [String] = [ScreenshotTestEvidence.eligibleCart]
    ) async throws -> ScreenshotAttemptEvaluation<RequesterOrderEvidence> {
        try await evaluation(on: makeRuntime(local: nil), texts)
    }

    /// The evaluation of a fresh attempt on `runtime`'s OWN fence: the only kind
    /// of evaluation that runtime will authorize an external transfer for.
    private func evaluation(
        on runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>,
        _ texts: [String] = [ScreenshotTestEvidence.eligibleCart]
    ) async throws -> ScreenshotAttemptEvaluation<RequesterOrderEvidence> {
        let images = texts.enumerated().map { ScreenshotTestEvidence.input($0.element, byte: UInt8($0.offset + 1)) }
        let selection = try XCTUnwrap(ScreenshotSelection(images: images))
        return try await evaluated(runtime, selection)
    }

    private func output(
        venue: String? = nil,
        items: [(String, Int?, [String])] = [("Bowl", 1, [])],
        swipes: Int? = nil
    ) -> RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: venue,
            foodItems: items.map { .init(name: $0.0, quantity: $0.1, modifiers: $0.2) },
            mealSwipes: swipes
        )
    }

    // MARK: - Capability vs. qualification are separate facts

    func testAvailabilityAndQualificationAreIndependent() {
        let available = StubLocalProvider(behavior: .output(output()))
        let unavailable = StubLocalProvider(availability: .unavailable(.modelNotEnabled), behavior: .output(output()))
        let qualified = qualifiedRegistry(environment: environment)
        let production = ScreenshotQualificationRegistry.production

        XCTAssertEqual(
            makeRuntime(local: available, qualification: qualified).localCapability(),
            ScreenshotLocalCapability(availability: .available, qualification: .qualified)
        )
        // Runtime model availability is not qualification.
        let availableButUnqualified = makeRuntime(local: available, qualification: production).localCapability()
        XCTAssertEqual(availableButUnqualified.availability, .available)
        XCTAssertEqual(availableButUnqualified.qualification, .notQualified)
        XCTAssertFalse(availableButUnqualified.permitsLocalAttempt)
        // Qualified evidence does not make an unavailable model usable.
        let qualifiedButUnavailable = makeRuntime(local: unavailable, qualification: qualified).localCapability()
        XCTAssertEqual(qualifiedButUnavailable.qualification, .qualified)
        XCTAssertEqual(qualifiedButUnavailable.availability, .unavailable(.modelNotEnabled))
        XCTAssertFalse(qualifiedButUnavailable.permitsLocalAttempt)
        XCTAssertTrue(makeRuntime(local: available, qualification: qualified).localCapability().permitsLocalAttempt)
    }

    // MARK: - Qualification identity fails closed

    private func key(
        workflow: ScreenshotWorkflowIdentity = RequesterOrderWorkflow.identity,
        provider: ScreenshotProviderIdentity = StubLocalProvider.stubIdentity,
        mode: ScreenshotInputMode = .ocrFlattenedText,
        fingerprint: String = ScreenshotQualificationFingerprint.current
    ) -> ScreenshotQualificationKey {
        ScreenshotQualificationKey(
            workflow: workflow,
            provider: provider,
            inputMode: mode,
            implementationFingerprint: fingerprint
        )
    }

    /// A permission minted the way the store does: from a token on the runtime's
    /// own fence, for exactly `evaluation`.
    private func mintPermission(
        _ runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>,
        for evaluation: ScreenshotAttemptEvaluation<RequesterOrderEvidence>
    ) throws -> ScreenshotExternalTransferPermission<RequesterOrderWorkflow> {
        try XCTUnwrap(runtime.authorizeExternalTransfer(for: evaluation.token, evaluation: evaluation))
    }

    func testProductionQualificationIsClosedForEveryProviderStrategyOSAndDevice() {
        XCTAssertTrue(ScreenshotQualificationRegistry.production.entries.isEmpty)
        XCTAssertFalse(ScreenshotQualificationRegistry.production.admitsNonShippingProviders)

        // The real shipped Requester provider identities, plus a stub, across
        // every evidence strategy, several OS bands, and device ids.
        let providers: [ScreenshotProviderIdentity] = [
            .shipping(id: "apple.foundation-models", strategyVersion: "requester-order-prompt-1"),
            .shipping(id: "openai.commonplate-screenshot-proposal", strategyVersion: "backend-route-1"),
            StubLocalProvider.stubIdentity,
        ]
        for provider in providers {
            for mode in ScreenshotInputMode.allCases {
                for identifier in ["iPhone17,1", "iPhone16,2", "iPad14,1", "simulator", "arm64"] {
                    for (major, minor) in [(17, 6), (18, 0), (26, 0), (26, 4), (27, 0)] {
                        XCTAssertEqual(
                            ScreenshotQualificationRegistry.production.qualification(
                                for: key(provider: provider, mode: mode),
                                environment: ScreenshotDeviceEnvironment(
                                    osVersion: ScreenshotOSVersion(major: major, minor: minor),
                                    modelIdentifier: identifier
                                )
                            ),
                            .notQualified
                        )
                    }
                }
            }
        }
    }

    /// Every component of the key is independently required: changing exactly
    /// one of them, however slightly, is a different — unqualified — combination.
    func testEveryQualificationKeyComponentIsIndependentlyRequired() {
        let registry = qualifiedRegistry(environment: environment)
        func qualification(
            key: ScreenshotQualificationKey,
            os: ScreenshotOSVersion = testQualifiableEnvironment.osVersion,
            device: String = testQualifiableEnvironment.modelIdentifier
        ) -> ScreenshotLocalQualification {
            registry.qualification(
                for: key,
                environment: ScreenshotDeviceEnvironment(osVersion: os, modelIdentifier: device)
            )
        }
        let workflow = RequesterOrderWorkflow.identity
        let provider = StubLocalProvider.stubIdentity

        XCTAssertEqual(qualification(key: key()), .qualified)

        // Workflow/schema.
        XCTAssertEqual(qualification(key: key(workflow: ScreenshotWorkflowIdentity(
            schemaID: "helper.order", schemaVersion: workflow.schemaVersion, validatorVersion: workflow.validatorVersion
        ))), .notQualified, "another workflow")
        XCTAssertEqual(qualification(key: key(workflow: ScreenshotWorkflowIdentity(
            schemaID: workflow.schemaID, schemaVersion: workflow.schemaVersion + 1, validatorVersion: workflow.validatorVersion
        ))), .notQualified, "another schema version")
        XCTAssertEqual(qualification(key: key(workflow: ScreenshotWorkflowIdentity(
            schemaID: workflow.schemaID, schemaVersion: workflow.schemaVersion, validatorVersion: workflow.validatorVersion + 1
        ))), .notQualified, "another validator version")

        // Provider.
        XCTAssertEqual(qualification(key: key(provider: .nonShipping(
            id: "test.other-provider", strategyVersion: provider.strategyVersion
        ))), .notQualified, "another provider")
        XCTAssertEqual(qualification(key: key(provider: .nonShipping(
            id: provider.id, strategyVersion: "2"
        ))), .notQualified, "another prompt/model/provider strategy version")
        XCTAssertEqual(qualification(key: key(provider: .shipping(
            id: provider.id, strategyVersion: provider.strategyVersion
        ))), .notQualified, "a shipping identity is not the qualified non-shipping identity")

        // Evidence/input strategy.
        for other in ScreenshotInputMode.allCases where other != .ocrFlattenedText {
            XCTAssertEqual(qualification(key: key(mode: other)), .notQualified, "strategy \(other)")
        }

        // OS major.minor band and device.
        let os = testQualifiableEnvironment.osVersion
        XCTAssertEqual(qualification(key: key(), os: ScreenshotOSVersion(major: os.major, minor: os.minor + 1)), .notQualified)
        XCTAssertEqual(qualification(key: key(), os: ScreenshotOSVersion(major: os.major + 1, minor: os.minor)), .notQualified)
        XCTAssertEqual(qualification(key: key(), os: ScreenshotOSVersion(major: os.major - 1, minor: 9)), .notQualified)
        XCTAssertEqual(qualification(key: key(), device: "iPhoneOther9,9"), .notQualified)
    }

    /// An OS entry is an explicit major.minor band, not a major: later minors
    /// and later majors outside the band fail closed.
    func testOSBandIsExplicitMajorMinorAndLaterVersionsFailClosed() {
        let band = ScreenshotQualificationEntry(
            key: key(),
            osBand: ScreenshotOSVersion(major: 26, minor: 0)...ScreenshotOSVersion(major: 26, minor: 3),
            deviceModelIdentifiers: ["iPhoneTest1,1"]
        )
        let registry = ScreenshotQualificationRegistry.injectedForTesting(entries: [band])
        func qualification(_ major: Int, _ minor: Int) -> ScreenshotLocalQualification {
            registry.qualification(
                for: key(),
                environment: ScreenshotDeviceEnvironment(
                    osVersion: ScreenshotOSVersion(major: major, minor: minor),
                    modelIdentifier: "iPhoneTest1,1"
                )
            )
        }
        XCTAssertEqual(qualification(26, 0), .qualified)
        XCTAssertEqual(qualification(26, 2), .qualified)
        XCTAssertEqual(qualification(26, 3), .qualified)
        XCTAssertEqual(qualification(26, 4), .notQualified, "the next minor is unknown")
        XCTAssertEqual(qualification(27, 0), .notQualified, "the next major is unknown")
        XCTAssertEqual(qualification(25, 9), .notQualified, "an earlier band is unknown")
    }

    /// Simulator/unit proof alone never qualifies a path, even if an entry were
    /// (wrongly) written for it.
    func testSimulatorIsNeverQualified() {
        let simulator = ScreenshotDeviceEnvironment(
            osVersion: ScreenshotOSVersion(major: 26, minor: 0),
            modelIdentifier: ScreenshotDeviceEnvironment.simulatorModelIdentifier
        )
        XCTAssertEqual(
            qualifiedRegistry(environment: simulator).qualification(for: key(), environment: simulator),
            .notQualified
        )
    }

    /// Test, debug, and conformance providers cannot be qualified into a
    /// shipped registry: the shipping constructor drops their entries, and even
    /// a registry that somehow held one refuses to qualify them.
    func testNonShippingProvidersCannotBeQualifiedByAShippingRegistry() {
        let nonShippingEntry = ScreenshotQualificationEntry(
            key: key(),
            osBand: environment.osVersion...environment.osVersion,
            deviceModelIdentifiers: [environment.modelIdentifier]
        )
        let shippingProvider = ScreenshotProviderIdentity.shipping(id: "apple.foundation-models", strategyVersion: "x")
        let shippingEntry = ScreenshotQualificationEntry(
            key: key(provider: shippingProvider),
            osBand: environment.osVersion...environment.osVersion,
            deviceModelIdentifiers: [environment.modelIdentifier]
        )

        let shipped = ScreenshotQualificationRegistry(shippingEntries: [nonShippingEntry, shippingEntry])
        XCTAssertEqual(shipped.entries, [shippingEntry], "the non-shipping entry is dropped at construction")
        XCTAssertFalse(shipped.admitsNonShippingProviders)
        XCTAssertEqual(shipped.qualification(for: key(), environment: environment), .notQualified)
        XCTAssertEqual(shipped.qualification(for: key(provider: shippingProvider), environment: environment), .qualified)

        // Only the explicit test injection admits a non-shipping provider.
        let injected = ScreenshotQualificationRegistry.injectedForTesting(entries: [nonShippingEntry])
        XCTAssertTrue(injected.admitsNonShippingProviders)
        XCTAssertEqual(injected.qualification(for: key(), environment: environment), .qualified)
    }

    // MARK: - Injected-qualified local path

    func testQualifiedLocalPathProducesAValidatedProposalWithoutTheExternalProvider() async throws {
        let local = StubLocalProvider(behavior: .output(output(
            venue: "Jasper Kane Cafe", items: [("Create Your Own Bowl", 1, ["Chicken", "No Side"])], swipes: 1
        )))
        let external = StubExternalProvider()
        let runtime = makeRuntime(local: local, external: external)

        let result = await runtime.runLocal(
            try await evaluation(["Your Pickup Order\nContinue to Checkout\nJasper Kane Cafe\nBowl 1M"])
        )

        guard case .completed(let analysis) = result else { return XCTFail("expected a completed local attempt") }
        let outcome = analysis.outcome
        XCTAssertTrue(outcome.eligible)
        XCTAssertEqual(outcome.proposal.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(outcome.proposal.mealItems, [MealItem(name: "1 Create Your Own Bowl", details: "Chicken, No Side")])
        XCTAssertEqual(outcome.proposal.mealSwipes, 1)
        XCTAssertTrue(analysis.evidence.isEmpty, "Requester accepts no provider-cited evidence")
        XCTAssertEqual(local.extractCallCount, 1)
        XCTAssertEqual(external.analyzeCallCount, 0, "a local attempt never touches the external provider")
    }

    func testUnavailableLocalModelNeverRunsAndReportsWhy() async throws {
        let local = StubLocalProvider(availability: .unavailable(.deviceNotEligible), behavior: .output(output()))
        let result = await makeRuntime(local: local).runLocal(try await evaluation())
        guard case .localUnavailable(let reason) = result else { return XCTFail("expected unavailable") }
        XCTAssertEqual(reason, .deviceNotEligible)
        XCTAssertEqual(local.extractCallCount, 0)
    }

    func testUnqualifiedLocalModelNeverRuns() async throws {
        let local = StubLocalProvider(behavior: .output(output()))
        let runtime = makeRuntime(local: local, qualification: .production)
        let result = await runtime.runLocal(try await evaluation())
        guard case .localUnavailable(let reason) = result else { return XCTFail("expected unavailable") }
        XCTAssertNil(reason, "not qualified is reported without an availability reason")
        XCTAssertEqual(local.extractCallCount, 0, "an available but unqualified model must not be invoked")
    }

    /// With no qualification entry the provider is neither invoked nor even
    /// asked whether it is available: the production state consults no local
    /// model at all. Availability is asked only of a qualified provider.
    func testUnqualifiedProviderIsNeitherInvokedNorAskedForAvailability() async throws {
        let local = StubLocalProvider(availability: .unavailable(.modelNotEnabled), behavior: .output(output()))
        let runtime = makeRuntime(local: local, qualification: .production)

        let result = await runtime.runLocal(try await evaluation())

        guard case .localUnavailable(let reason) = result else { return XCTFail("expected unavailable") }
        XCTAssertNil(reason, "nonqualification is reported without consulting the model's availability")
        XCTAssertEqual(local.availabilityCallCount, 0)
        XCTAssertEqual(local.extractCallCount, 0)

        // A qualified provider IS asked, and availability then decides.
        let qualifiedRuntime = makeRuntime(local: local)
        guard case .localUnavailable(let qualifiedReason) = await qualifiedRuntime.runLocal(try await evaluation()) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertEqual(qualifiedReason, .modelNotEnabled)
        XCTAssertEqual(local.availabilityCallCount, 1)
        XCTAssertEqual(local.extractCallCount, 0)
    }

    func testMissingLocalProviderReportsUnavailable() async throws {
        let result = await makeRuntime(local: nil).runLocal(try await evaluation())
        guard case .localUnavailable(let reason) = result else { return XCTFail("expected unavailable") }
        XCTAssertEqual(reason, .osTooOld)
    }

    func testLocalProviderFailureIsReportedAsAFailureNotAnEmptyResult() async throws {
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let result = await makeRuntime(local: local).runLocal(try await evaluation())
        guard case .failed = result else { return XCTFail("expected a failure") }
    }

    func testLocalAttemptIsBoundedByATimeout() async throws {
        let local = StubLocalProvider(behavior: .hang)
        let runtime = makeRuntime(local: local, timeout: .milliseconds(80))
        let started = ContinuousClock.now
        let result = await runtime.runLocal(try await evaluation())
        guard case .failed(let error) = result, case ScreenshotAnalysisFailure.timedOut = error else {
            return XCTFail("expected a timeout failure")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testCancellingALocalAttemptReportsCancelledNotAFailure() async throws {
        let local = StubLocalProvider(behavior: .hang)
        let runtime = makeRuntime(local: local)
        let evaluation = try await evaluation()
        let task = Task { await runtime.runLocal(evaluation) }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        guard case .cancelled = await task.value else { return XCTFail("expected cancelled") }
    }

    // MARK: - On-device validation applies to every local result

    /// Provider output is never proposal authority by itself: a venue the
    /// independent evidence does not name, and a swipe count the evidence does
    /// not corroborate, are dropped.
    func testLocalOutputThatIndependentEvidenceDoesNotSupportIsDropped() async throws {
        let local = StubLocalProvider(behavior: .output(output(venue: "Cafe 370", items: [], swipes: 3)))
        let result = await makeRuntime(local: local).runLocal(try await evaluation())
        guard case .completed(let analysis) = result else { return XCTFail("expected completed") }
        XCTAssertTrue(analysis.outcome.isEmpty, "ungrounded venue and uncorroborated swipes must not survive")
    }

    func testOCRDerivedStrategiesNeverProposeDiningDollars() async throws {
        for mode in [ScreenshotInputMode.ocrFlattenedText, .ocrLayoutAware] {
            let local = StubLocalProvider(inputMode: mode, behavior: .output(output(items: [("Bowl", nil, [])], swipes: 3)))
            let runtime = makeRuntime(
                local: local,
                qualification: qualifiedRegistry(inputMode: mode, environment: environment)
            )
            let result = await runtime.runLocal(try await evaluation(["Your pickup order\n3M + $2.00"]))
            guard case .completed(let analysis) = result else { return XCTFail("expected completed for \(mode)") }
            XCTAssertEqual(analysis.outcome.proposal.mealSwipes, 3, "\(mode)")
            XCTAssertNil(analysis.outcome.proposal.estimatedDiningDollarsCents, "\(mode)")
        }
    }

    func testQualifiedDirectImageModeMayProposeCorroboratedDiningDollars() async throws {
        let local = StubLocalProvider(
            inputMode: .directImageMultimodal,
            behavior: .output(output(items: [("Bowl", nil, [])], swipes: 3))
        )
        let runtime = makeRuntime(
            local: local,
            qualification: qualifiedRegistry(inputMode: .directImageMultimodal, environment: environment)
        )
        let result = await runtime.runLocal(try await evaluation(["Your pickup order\n3M + $2.00"]))
        guard case .completed(let analysis) = result else { return XCTFail("expected completed") }
        XCTAssertEqual(analysis.outcome.proposal.estimatedDiningDollarsCents, 200)
    }

    /// The evidence/input strategy is part of qualification identity: only the
    /// exact strategy a registry qualified can run, and no qualification
    /// transfers between strategies.
    func testEvidenceStrategyParticipatesInQualificationAcrossEveryPair() async throws {
        for providerMode in ScreenshotInputMode.allCases {
            for qualifiedMode in ScreenshotInputMode.allCases {
                let local = StubLocalProvider(inputMode: providerMode, behavior: .output(output()))
                let runtime = makeRuntime(
                    local: local,
                    qualification: qualifiedRegistry(inputMode: qualifiedMode, environment: environment)
                )
                let result = await runtime.runLocal(try await evaluation())
                if providerMode == qualifiedMode {
                    guard case .completed = result else { return XCTFail("\(providerMode) should run") }
                    XCTAssertEqual(local.extractCallCount, 1)
                } else {
                    guard case .localUnavailable = result else {
                        return XCTFail("\(providerMode) must not run under a \(qualifiedMode) qualification")
                    }
                    XCTAssertEqual(local.extractCallCount, 0)
                }
            }
        }
    }

    func testEvidenceStrategyIndependenceFactIsWorkflowNeutral() {
        XCTAssertTrue(ScreenshotInputMode.ocrFlattenedText.consumesRuntimeOCREvidence)
        XCTAssertTrue(ScreenshotInputMode.ocrLayoutAware.consumesRuntimeOCREvidence)
        XCTAssertFalse(ScreenshotInputMode.directImageMultimodal.consumesRuntimeOCREvidence)
        XCTAssertEqual(Set(ScreenshotInputMode.allCases.map(\.rawValue)).count, ScreenshotInputMode.allCases.count)
    }

    // MARK: - Requester eligibility gate (workflow adapter) and ordered selection

    func testEvaluationKeepsOnlyEligibleScreenshotsAndTheirEvidenceWithOriginalIndices() async throws {
        let images = [
            ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
            ScreenshotTestEvidence.input("Your Delivery Order\nAdd more items", byte: 2),
            ScreenshotTestEvidence.input("Menu popular items rating delivery fee only", byte: 3),
            ScreenshotTestEvidence.input("Items subtotal 12.00 tax fee tip total", byte: 4),
        ]
        let selection = try XCTUnwrap(ScreenshotSelection(images: images))
        let evaluation = try await evaluated(makeRuntime(local: nil), selection)
        XCTAssertEqual(evaluation.selection.items.map { $0.image.data.first }, [2, 4])
        XCTAssertEqual(evaluation.selection.items.map(\.index), [1, 3], "original selection positions are retained")
        XCTAssertEqual(
            evaluation.derived.combinedText,
            "Your Delivery Order\nAdd more items\nItems subtotal 12.00 tax fee tip total"
        )
        XCTAssertEqual(evaluation.derived.orderedTexts(for: evaluation.selection), [
            "Your Delivery Order\nAdd more items",
            "Items subtotal 12.00 tax fee tip total",
        ])
    }

    func testWhollyIneligibleSelectionHasNoEvaluation() async throws {
        let runtime = makeRuntime(local: nil)
        let ineligible = try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible)]))
        let none = await runtime.evaluate(ineligible, for: runtime.fence.beginAttempt())
        XCTAssertNil(none)
        XCTAssertNil(ScreenshotSelection(images: []), "an empty selection cannot exist")
    }

    /// The runtime hands providers the complete, ordered, eligible selection as
    /// one logical input — one call for the whole set, never one per image.
    func testProviderReceivesTheCompleteOrderedSelectionInOneCall() async throws {
        let local = StubLocalProvider(behavior: .output(output()))
        let external = StubExternalProvider()
        let runtime = makeRuntime(local: local, external: external)
        let texts = [
            "Your Pickup Order first",
            ScreenshotTestEvidence.ineligible,
            "Your Pickup Order third",
            "Your Pickup Order fourth",
            ScreenshotTestEvidence.ineligible,
        ]
        let images = texts.enumerated().map { ScreenshotTestEvidence.input($0.element, byte: UInt8($0.offset + 1)) }
        let selection = try XCTUnwrap(ScreenshotSelection(images: images))
        let evaluation = try await evaluated(runtime, selection)
        _ = await runtime.runLocal(evaluation)
        XCTAssertEqual(local.extractCallCount, 1, "one attempt for the whole set")
        XCTAssertEqual(local.lastInput?.selection.items.map(\.index), [0, 2, 3])
        XCTAssertEqual(local.lastInput?.selection.items.map { $0.image.data.first }, [1, 3, 4])
        XCTAssertEqual(local.lastEvidenceTexts, ["Your Pickup Order first", "Your Pickup Order third", "Your Pickup Order fourth"])

        _ = try await runtime.runExternal(authority: { "a" }, permission: try mintPermission(runtime, for: evaluation))
        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertEqual(external.lastInput?.selection.items.map(\.index), [0, 2, 3])
        XCTAssertEqual(external.lastImages.map { $0.data.first }, [1, 3, 4])
    }

    func testSelectionSubsetPreservesOrderAndOriginalIndices() throws {
        let images = ScreenshotTestEvidence.inputs(5)
        let selection = try XCTUnwrap(ScreenshotSelection(images: images))
        XCTAssertEqual(selection.items.map(\.index), [0, 1, 2, 3, 4])
        let subset = try XCTUnwrap(selection.retaining([4, 0, 2]))
        XCTAssertEqual(subset.items.map(\.index), [0, 2, 4], "order is selection order, not request order")
        XCTAssertEqual(subset.items.map { $0.image.data.first }, [1, 3, 5])
        XCTAssertNil(selection.retaining([]))
        XCTAssertNil(selection.retaining([9]))
    }

    func testLocalContextIsBoundedAndKeepsEveryScreenshotOfAOneToFiveSet() {
        for count in 1...5 {
            let texts = (1...count).map { index in "S\(index) " + String(repeating: "x", count: 20_000) }
            let bounded = RequesterOrderLocalPromptBuilder.boundedEvidence(texts)
            XCTAssertEqual(bounded.count, count, "ordering and count are preserved")
            XCTAssertLessThanOrEqual(
                bounded.reduce(0) { $0 + $1.count },
                RequesterOrderLocalPromptBuilder.totalEvidenceCharacterBudget
            )
            for (index, text) in bounded.enumerated() {
                XCTAssertTrue(text.hasPrefix("S\(index + 1) "), "screenshot \(index + 1) keeps its own opening evidence")
                XCTAssertLessThanOrEqual(text.count, RequesterOrderLocalPromptBuilder.perScreenshotCharacterCeiling)
            }
        }
        XCTAssertEqual(RequesterOrderLocalPromptBuilder.boundedEvidence([]), [])
    }

    func testShortEvidenceIsPassedThroughUnchangedAndPromptLabelsEachScreenshot() {
        let prompt = RequesterOrderLocalPromptBuilder.prompt(for: ["  first text  ", "second text"])
        XCTAssertTrue(prompt.contains("Screenshot 1 of 2"))
        XCTAssertTrue(prompt.contains("Screenshot 2 of 2"))
        XCTAssertTrue(prompt.contains("first text"))
        XCTAssertTrue(prompt.contains("second text"))
    }

    // MARK: - External: explicit single-use permission, re-validated result

    func testExternalTransferRequiresAndConsumesItsPermissionExactlyOnce() async throws {
        let external = StubExternalProvider()
        let runtime = makeRuntime(local: nil, external: external)
        let evaluation = try await evaluation(on: runtime)
        let permission = try mintPermission(runtime, for: evaluation)

        _ = try await runtime.runExternal(authority: { "a" }, permission: permission)
        XCTAssertEqual(external.analyzeCallCount, 1)

        do {
            _ = try await runtime.runExternal(authority: { "a" }, permission: permission)
            XCTFail("a consumed permission must never authorize a second transfer")
        } catch ScreenshotAnalysisFailure.permissionUnavailable {
            // expected
        }
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testEachExternalAttemptNeedsItsOwnPermission() async throws {
        let external = StubExternalProvider()
        let runtime = makeRuntime(local: nil, external: external)
        let firstEvaluation = try await evaluation(on: runtime)
        let first = try mintPermission(runtime, for: firstEvaluation)
        _ = try await runtime.runExternal(authority: { "a" }, permission: first)
        // A new attempt (a new selection) evaluates and mints its own permission.
        let secondEvaluation = try await evaluation(on: runtime)
        let second = try mintPermission(runtime, for: secondEvaluation)
        XCTAssertNotEqual(first.token, second.token)
        _ = try await runtime.runExternal(authority: { "a" }, permission: second)
        XCTAssertEqual(external.analyzeCallCount, 2)
    }

    /// The external provider (and the backend behind it) does not establish
    /// eligibility or authority: its result is re-checked on device against the
    /// independent evidence and unsupported fields are dropped.
    func testExternalResultIsRevalidatedAgainstOnDeviceEvidence() async throws {
        let cafe = try XCTUnwrap(SupportedVendorCatalog.diningSpots.first { $0.name == "Cafe 370" })
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: cafe,
                mealItems: [MealItem(name: "  Bowl  ", details: "  Rice "), MealItem(name: "   ")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 500
            )
        )))
        let runtime = makeRuntime(local: nil, external: external)

        // Evidence names Jasper Kane Cafe (not Cafe 370), shows no `3M`, and has no
        // matching Dining Dollars expression.
        let analysis = try await runtime.runExternal(
            authority: { "a" },
            permission: try mintPermission(runtime, for: try await evaluation(on: runtime))
        )
        let outcome = analysis.outcome
        XCTAssertNil(outcome.proposal.selectedDiningSpot)
        XCTAssertNil(outcome.proposal.mealSwipes)
        XCTAssertNil(outcome.proposal.estimatedDiningDollarsCents)
        XCTAssertEqual(outcome.proposal.mealItems, [MealItem(name: "Bowl", details: "Rice")])
    }

    func testCorroboratedExternalFieldsSurviveValidation() async throws {
        let palladium = try XCTUnwrap(SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" })
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: palladium,
                mealItems: [MealItem(name: "Bowl")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 200
            )
        )))
        let runtime = makeRuntime(local: nil, external: external)
        let analysis = try await runtime.runExternal(
            authority: { "a" },
            permission: try mintPermission(runtime, for: try await evaluation(on: runtime, ["Your pickup order\nJasper Kane Cafe\n3M + $2.00"]))
        )
        let outcome = analysis.outcome
        XCTAssertEqual(outcome.proposal.selectedDiningSpot, palladium)
        XCTAssertEqual(outcome.proposal.mealSwipes, 3)
        XCTAssertEqual(outcome.proposal.estimatedDiningDollarsCents, 200)
    }

    /// The Dining Dollars rule for the external path is the same Requester
    /// policy the local path uses, applied to the external provider's declared
    /// strategy: a strategy that reads the same OCR text cannot corroborate itself.
    func testExternalDiningDollarsFollowTheRequesterPolicyForTheProvidersDeclaredStrategy() async throws {
        let palladium = try XCTUnwrap(SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" })
        let proposal = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium, mealSwipes: 3, estimatedDiningDollarsCents: 200)
        )
        for (mode, expected) in [
            (ScreenshotInputMode.directImageMultimodal, Optional(200)),
            (.ocrFlattenedText, nil),
            (.ocrLayoutAware, nil),
        ] {
            let external = StubExternalProvider(result: .success(proposal))
            external.inputMode = mode
            let runtime = makeRuntime(local: nil, external: external)
            let analysis = try await runtime.runExternal(
                authority: { "a" },
                permission: try mintPermission(runtime, for: try await evaluation(on: runtime, ["Your pickup order\nJasper Kane Cafe\n3M + $2.00"]))
            )
            XCTAssertEqual(analysis.outcome.proposal.estimatedDiningDollarsCents, expected, "\(mode)")
            XCTAssertEqual(analysis.outcome.proposal.mealSwipes, 3, "\(mode)")
        }
    }

    func testExternalIneligibleFlagNeverBecomesEligible() async throws {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: false, proposal: .empty)))
        let runtime = makeRuntime(local: nil, external: external)
        let analysis = try await runtime.runExternal(
            authority: { "a" },
            permission: try mintPermission(runtime, for: try await evaluation(on: runtime))
        )
        XCTAssertFalse(analysis.outcome.eligible)
    }

    // MARK: - Local privacy: no persistence, network, or logging in local files

    func testLocalAnalysisSourcesContainNoPersistenceNetworkOrLoggingSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance")
        // Everything that handles content locally. The external provider adapter
        // (`RequesterOpenAIExternalProvider.swift`) is the one file that may
        // reach the network, and only through `ScreenshotProposalService`.
        let localFiles = [
            "ScreenshotSelection.swift",
            "ScreenshotEvidence.swift",
            "ScreenshotQualification.swift",
            "ScreenshotWorkflow.swift",
            "ScreenshotProviders.swift",
            "ScreenshotTextRecognizing.swift",
            "ScreenshotInputPreparer.swift",
            "ScreenshotAttemptFence.swift",
            "Requester/RequesterAppleOnDeviceProvider.swift",
            "Requester/RequesterOrderDeterministicEvidence.swift",
            "Requester/RequesterOrderOutputValidator.swift",
            "Requester/RequesterOrderWorkflow.swift",
        ]
        let forbidden = [
            "UserDefaults", "FileManager", ".write(", "URLSession", "URLRequest", "APIClient",
            "print(", "NSLog", "os_log", "Logger(", "Keychain", "UIPasteboard", "Datadog", "RUMMonitor",
            "temporaryDirectory", "cachesDirectory", "documentDirectory", "CoreData", "SwiftData",
        ]
        for file in localFiles {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(file) must not contain `\(token)`")
            }
        }
        // The runtime reaches the network only through the external provider
        // abstraction, never directly.
        let runtime = try String(contentsOf: directory.appendingPathComponent("ScreenshotAssistanceRuntime.swift"), encoding: .utf8)
        for token in ["URLSession", "APIClient", "UserDefaults", "print(", "NSLog"] {
            XCTAssertFalse(runtime.contains(token), "the runtime must not contain `\(token)`")
        }
    }
}
