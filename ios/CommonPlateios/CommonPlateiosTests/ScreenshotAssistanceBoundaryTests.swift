//
//  ScreenshotAssistanceBoundaryTests.swift
//  CommonPlateiosTests
//
// W4-S3 structural boundary proof, by source inspection of the app target. These
// are tripwires for architecture that runtime tests cannot observe directly:
//
// - the shared runtime carries no Requester vocabulary and no text-shaped input;
// - exactly the shipped Requester adapters conform to the workflow/provider
//   contracts, so no test/debug/conformance provider can be in the app;
// - test-injection APIs and test-target types are unreachable from app code;
// - Foundation Models and the external transfer are reachable only through the
//   runtime that enforces qualification and per-attempt permission;
// - production Requester wiring uses the closed registry and shipping providers;
// - evidence never reaches the store or the view;
// - no Datadog / observability dependency exists in the app target or project.
//
// Behavior is proved by the runtime, routing, and conformance suites; this file
// proves only what source structure can. It does not exercise a rendered view.
import Foundation
import XCTest
@testable import CommonPlateios

enum ScreenshotBoundarySource {
    static func root(from filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
    }

    static func read(_ relativePath: String, from filePath: String) throws -> String {
        try String(contentsOf: root(from: filePath).appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The source with comment-only lines removed, so a comment that NAMES a
    /// forbidden concept (to explain why it is absent) is not mistaken for code.
    static func codeLines(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every `.swift` file in the app target: relative path (from the app
    /// target directory) → comment-stripped code.
    static func appCode(from filePath: String) throws -> [String: String] {
        let appDirectory = root(from: filePath).appendingPathComponent("ios/CommonPlateios/CommonPlateios")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(appDirectory.path.count + 1))
            result[relative] = codeLines(try String(contentsOf: url, encoding: .utf8))
        }
        return result
    }

    /// Removes generic parameter lists (`<Workflow: ScreenshotWorkflow>`) so a
    /// generic CONSTRAINT is not mistaken for a conformance. Only a `<` that
    /// directly follows an identifier, and closes on the same line without
    /// crossing a brace, is a generic list — so `a < b` and `->` can never
    /// swallow a declaration.
    static func strippingGenerics(_ code: String) -> String {
        var text = code
        while let range = text.range(of: #"(?<=\w)<[^<>{}\n]*>"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "")
        }
        return text
    }

    /// Names of types declared with a conformance to any of `protocols`.
    static func conformers(in code: String, to protocols: Set<String>) -> Set<String> {
        let stripped = strippingGenerics(code)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:class|struct|enum|extension)\s+(\w+)\s*:\s*([^{]*)\{"#
        ) else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        var names: Set<String> = []
        for match in regex.matches(in: stripped, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: stripped),
                  let listRange = Range(match.range(at: 2), in: stripped) else { continue }
            let adopted = stripped[listRange]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if adopted.contains(where: { protocols.contains($0) }) {
                names.insert(String(stripped[nameRange]))
            }
        }
        return names
    }
}

@MainActor
final class ScreenshotAssistanceBoundaryTests: XCTestCase {
    private let directory = "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance"

    private func source(_ relativePath: String) throws -> String {
        try ScreenshotBoundarySource.read(relativePath, from: #filePath)
    }

    private func sharedCode(_ file: String) throws -> String {
        ScreenshotBoundarySource.codeLines(try source("\(directory)/\(file)"))
    }

    private let sharedFiles = [
        "ScreenshotAssistanceRuntime.swift", "ScreenshotSelection.swift", "ScreenshotEvidence.swift",
        "ScreenshotQualification.swift", "ScreenshotWorkflow.swift", "ScreenshotProviders.swift",
        "ScreenshotAttemptFence.swift", "ScreenshotInputPreparer.swift", "ScreenshotTextRecognizing.swift",
    ]

    // MARK: - The shared layer is schema-neutral and pixel-first

    func testSharedRuntimeCodeHasNoRequesterVocabulary() throws {
        let forbidden = [
            "Requester", "requester", "DiningSpot", "MealItem", "ScreenshotProposal", "SupportedVendorCatalog",
            "mealSwipes", "DiningDollars", "diningDollars", "Grubhub", "localEvidenceText", "evidenceText",
            "vendors",
        ]
        for file in sharedFiles {
            let code = try sharedCode(file)
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(file) must not contain the Requester concept `\(token)`")
            }
        }
    }

    func testTheSharedInputContractIsPixelsOnlyNotFlattenedText() throws {
        // The selection contract carries no recognized text of any kind.
        let selection = try sharedCode("ScreenshotSelection.swift").lowercased()
        for token in ["ocr", "recogni", "text", "layout"] {
            XCTAssertFalse(selection.contains(token), "ScreenshotSelection.swift must not model `\(token)`")
        }
        // What a provider receives is exactly the ordered selection plus the
        // workflow's opaque derived data — no OCR string field.
        let providers = try sharedCode("ScreenshotProviders.swift")
        let start = try XCTUnwrap(providers.range(of: "struct ScreenshotProviderInput"))
        let body = String(providers[start.lowerBound...].prefix(while: { $0 != "}" }))
        XCTAssertTrue(body.contains("let selection: ScreenshotSelection"))
        XCTAssertTrue(body.contains("let derived: Workflow.Derived"))
        XCTAssertFalse(body.contains("String"), "the provider input has no text-shaped field")
    }

    func testRuntimeIsGenericOverAWorkflowAndPreservesSelectionOrder() throws {
        let runtime = try sharedCode("ScreenshotAssistanceRuntime.swift")
        XCTAssertTrue(runtime.contains("final class ScreenshotAssistanceRuntime<Workflow: ScreenshotWorkflow>"))
        XCTAssertTrue(runtime.contains("func evaluate(_ selection: ScreenshotSelection, for token: ScreenshotSelectionToken)"))
        // No sort/shuffle/reversal of the selection anywhere in the shared layer.
        for file in sharedFiles {
            let code = try sharedCode(file)
            for token in [".sorted", ".sort(", ".shuffle", ".reversed()", ".reverse()"] {
                XCTAssertFalse(code.contains(token), "\(file) must not reorder a selection (`\(token)`)")
            }
        }
    }

    // MARK: - Only the shipped Requester adapters exist in the app

    func testOnlyTheRequesterAdaptersConformToTheContractsInTheAppTarget() throws {
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        var workflows: Set<String> = []
        var localProviders: Set<String> = []
        var externalProviders: Set<String> = []
        for (_, code) in app {
            workflows.formUnion(ScreenshotBoundarySource.conformers(in: code, to: ["ScreenshotWorkflow"]))
            localProviders.formUnion(ScreenshotBoundarySource.conformers(in: code, to: ["ScreenshotLocalProvider"]))
            externalProviders.formUnion(ScreenshotBoundarySource.conformers(in: code, to: ["ScreenshotExternalProvider"]))
        }
        XCTAssertEqual(workflows, ["RequesterOrderWorkflow"])
        XCTAssertEqual(localProviders, ["RequesterFoundationModelsProvider"])
        XCTAssertEqual(externalProviders, ["RequesterOpenAIExternalProvider"])
    }

    func testTestOnlyAPIsAndTypesAreUnreachableFromTheAppTarget() throws {
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        // The only file that may mention the test-injection API or the
        // non-shipping distribution is the qualification file that defines them.
        for (file, code) in app where file != "Services/ScreenshotAssistance/ScreenshotQualification.swift" {
            for token in ["injectedForTesting", ".nonShipping", "admitsNonShippingProviders"] {
                XCTAssertFalse(code.contains(token), "\(file) must not reference `\(token)`")
            }
        }
        for (file, code) in app {
            for token in [
                "StubLocalProvider", "StubExternalProvider", "SyntheticTextRecognizer", "ConformanceWorkflow",
                "ConformanceDirectImageProvider", "ConformanceLayoutProvider", "ConformanceScreenshot",
                "makeRequesterTestRuntime", "qualifiedRegistry", "NonCooperativeLocalProvider", "HookedTextRecognizer",
                "AuthorityBox", "makeStoreOver",
            ] {
                XCTAssertFalse(code.contains(token), "\(file) must not contain test-target type `\(token)`")
            }
        }
    }

    func testShippedProviderIdentitiesAreShippingAndDistinct() throws {
        let external = RequesterOpenAIExternalProvider(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: APIClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!)
            ))
        )
        XCTAssertEqual(external.identity.distribution, .shipping)
        XCTAssertEqual(external.inputMode, .directImageMultimodal)
        if let apple = RequesterAppleOnDeviceProviderFactory.make() {
            XCTAssertEqual(apple.identity.distribution, .shipping)
            XCTAssertNotEqual(apple.identity, external.identity)
            XCTAssertEqual(apple.inputMode, .ocrFlattenedText)
        }
        XCTAssertEqual(RequesterOrderWorkflow.identity.schemaID, "requester.order")
    }

    // MARK: - Foundation Models and remote transfer reach only through the runtime

    func testFoundationModelsAndProviderCallsAreReachedOnlyThroughTheEnforcingRuntime() throws {
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        let appleFile = "Services/ScreenshotAssistance/Requester/RequesterAppleOnDeviceProvider.swift"
        let runtimeFile = "Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift"
        for (file, code) in app {
            if file != appleFile {
                XCTAssertFalse(code.contains("LanguageModelSession("), "\(file) must not open a Foundation Models session")
                XCTAssertFalse(code.contains("import FoundationModels"), "\(file) must not import Foundation Models")
                XCTAssertFalse(code.contains("SystemLanguageModel"), "\(file) must not touch the system model")
            }
            if file != runtimeFile {
                XCTAssertFalse(code.contains(".extract("), "\(file) must not call a local provider directly")
                XCTAssertFalse(code.contains(".analyze("), "\(file) must not call an external provider directly")
            }
        }

        // Inside the runtime, each call sits behind its guard — searched inside
        // `runLocal`'s own body. Qualification comes first: the provider is
        // neither asked for availability nor invoked until it is qualified.
        let runtime = try XCTUnwrap(app[runtimeFile])
        let runLocalStart = try XCTUnwrap(runtime.range(of: "func runLocal("))
        let runLocal = String(runtime[runLocalStart.lowerBound...])
        let qualifiedGuard = try XCTUnwrap(runLocal.range(of: "guard localQualification(of: localProvider) == .qualified"))
        let availability = try XCTUnwrap(runLocal.range(of: "localProvider.availability()"))
        let extract = try XCTUnwrap(runLocal.range(of: "localProvider.extract("))
        XCTAssertLessThan(qualifiedGuard.lowerBound, availability.lowerBound, "qualification is decided before availability is asked")
        XCTAssertLessThan(availability.lowerBound, extract.lowerBound, "availability is checked before the provider runs")
        // The runtime itself refuses an already-used permission, one whose
        // attempt is no longer current, or one not bound to its evaluation's
        // attempt, and consumes it, before any transfer.
        let guardPermission = try XCTUnwrap(runtime.range(of: "guard permission.isUnused,"))
        let currentCheck = try XCTUnwrap(runtime.range(of: "fence.isCurrent(permission.token),"))
        let boundCheck = try XCTUnwrap(runtime.range(of: "evaluation.token == permission.token,"))
        let consume = try XCTUnwrap(runtime.range(of: "permission.consume() else"))
        let analyze = try XCTUnwrap(runtime.range(of: "externalProvider.analyze("))
        XCTAssertLessThan(guardPermission.lowerBound, currentCheck.lowerBound)
        XCTAssertLessThan(currentCheck.lowerBound, boundCheck.lowerBound)
        XCTAssertLessThan(boundCheck.lowerBound, consume.lowerBound)
        XCTAssertLessThan(consume.lowerBound, analyze.lowerBound, "permission is validated and consumed before any transfer")
        // What is sent is the evaluation the permission captured, never a second
        // caller-supplied one.
        XCTAssertTrue(runtime.contains("let evaluation = permission.evaluation"))
        XCTAssertFalse(runtime.contains("func runExternal(\n        _ evaluation"))
    }

    func testExternalTransferIsMintedAndRunOnlyByTheRequesterStoreAction() throws {
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        for (file, code) in app {
            for token in [".authorizeExternalTransfer(", ".runExternal("] {
                if file == "Stores/ScreenshotProposalStore.swift" || file == "Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift" {
                    continue
                }
                XCTAssertFalse(code.contains(token), "\(file) must not reach the external transfer (`\(token)`)")
            }
        }
        // In the store, both live only inside `attemptExternalFallback`, after
        // the participant-authority guard (W4-S3 consent-authority revision:
        // there is no separate pending-popup guard any more — standing
        // consent, checked earlier via `isAIAssistanceEnabled`, is what used
        // to gate presenting that popup at all).
        let store = try XCTUnwrap(app["Stores/ScreenshotProposalStore.swift"])
        // Everything below is searched inside `attemptExternalFallback`'s own
        // body, so an earlier method with a similar guard cannot satisfy the
        // ordering.
        let fallbackStart = try XCTUnwrap(store.range(of: "private func attemptExternalFallback("))
        let afterFallback = String(store[fallbackStart.lowerBound...])
        let body = String(afterFallback[..<(afterFallback.range(of: "\n    /// The existing requester treatment")?.lowerBound ?? afterFallback.endIndex)])
        let authorityGuard = try XCTUnwrap(body.range(of: "guard participantAuthority() != nil else"))
        let mint = try XCTUnwrap(body.range(of: "runtime.authorizeExternalTransfer("))
        let run = try XCTUnwrap(body.range(of: "runtime.runExternal("))
        XCTAssertLessThan(authorityGuard.lowerBound, mint.lowerBound)
        XCTAssertLessThan(mint.lowerBound, run.lowerBound)
        // And these are the only sites in the whole store.
        XCTAssertEqual(store.components(separatedBy: "runtime.runExternal(").count - 1, 1)
        XCTAssertEqual(store.components(separatedBy: "runtime.authorizeExternalTransfer(").count - 1, 1)
    }

    // MARK: - Production wiring

    func testProductionRequesterWiringUsesTheClosedRegistryAndShippingProvidersOnly() throws {
        let external = try sharedCode("Requester/RequesterOpenAIExternalProvider.swift")
        let start = try XCTUnwrap(external.range(of: "enum RequesterScreenshotAssistanceProduction"))
        let wiring = String(external[start.lowerBound...])
        XCTAssertTrue(wiring.contains("RequesterOrderWorkflow()"))
        XCTAssertTrue(wiring.contains("RequesterAppleOnDeviceProviderFactory.make()"))
        XCTAssertTrue(wiring.contains("RequesterOpenAIExternalProvider(service: service)"))
        // No registry or environment is passed: the runtime resolves the
        // production (empty) registry and the real device environment itself.
        XCTAssertFalse(wiring.contains("qualification:"))
        XCTAssertFalse(wiring.contains("environment:"))
        XCTAssertTrue(try sharedCode("ScreenshotAssistanceRuntime.swift").contains("qualification ?? .production"))

        let store = ScreenshotBoundarySource.codeLines(try source("ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift"))
        XCTAssertTrue(store.contains("runtime ?? RequesterScreenshotAssistanceProduction.makeRuntime(service: service)"))

        XCTAssertTrue(ScreenshotQualificationRegistry.production.entries.isEmpty)
        XCTAssertFalse(ScreenshotQualificationRegistry.production.admitsNonShippingProviders)
    }

    // MARK: - Evidence stays out of the store and the view

    func testEvidenceNeverReachesTheStoreOrTheView() throws {
        let evidenceTokens = [
            "ScreenshotEvidence", "ScreenshotEvidenceSet", "ScreenshotEvidenceEntry", "ScreenshotEvidenceRegion",
            "ScreenshotProviderResult", ".evidence",
        ]
        for file in [
            "ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift",
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            "ios/CommonPlateios/CommonPlateios/CommonPlateiosApp.swift",
        ] {
            let code = ScreenshotBoundarySource.codeLines(try source(file))
            for token in evidenceTokens {
                XCTAssertFalse(code.contains(token), "\(file) must not touch provenance (`\(token)`)")
            }
        }
    }

    // MARK: - No observability dependency

    func testNoDatadogOrObservabilityDependencyRemainsInTheAppTargetOrProject() throws {
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        for (file, code) in app {
            for token in ["Datadog", "RUMMonitor", "ScreenshotAssistanceTelemetry", "endTelemetryAttempt", "onTransferAccepted", "onRequestSubmi"] {
                XCTAssertFalse(code.contains(token), "\(file) must not reference `\(token)`")
            }
        }
        let project = try source("ios/CommonPlateios/CommonPlateios.xcodeproj/project.pbxproj")
        for token in ["Datadog", "dd-sdk-ios", "XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency"] {
            XCTAssertFalse(project.contains(token), "the project must not reference `\(token)`")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ScreenshotBoundarySource.root(from: #filePath)
                .appendingPathComponent("ios/CommonPlateios/CommonPlateios.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").path),
            "no stale SwiftPM resolution remains"
        )
    }
}
