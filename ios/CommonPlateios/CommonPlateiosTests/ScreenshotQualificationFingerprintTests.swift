//
//  ScreenshotQualificationFingerprintTests.swift
//  CommonPlateiosTests
//
// W4-S3 ACTIVE / FIX, D2: qualification validity is mechanically tied to the
// qualification-relevant implementation, not to remembered version strings. A
// build phase ("Derive Screenshot Qualification Fingerprint") hashes every
// declared input into a generated Swift constant, and that constant is part of
// the qualification key. These cases recompute the fingerprint independently in
// Swift from the phase's OWN declared inputs in the project file, so the phase,
// the generated constant, and the declared input set cannot drift apart.
//
// The production registry stays EMPTY; no Apple candidate is qualified.
import CryptoKit
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotQualificationFingerprintTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    // MARK: - Independent recomputation

    private static let phaseName = "Derive Screenshot Qualification Fingerprint"
    private static let hashedDirectory = "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance"

    private var repoRoot: URL {
        ScreenshotBoundarySource.root(from: #filePath).resolvingSymlinksInPath()
    }

    private var projectDirectory: URL {
        repoRoot.appendingPathComponent("ios/CommonPlateios")
    }

    private func pbxproj() throws -> String {
        try ScreenshotBoundarySource.read("ios/CommonPlateios/CommonPlateios.xcodeproj/project.pbxproj", from: #filePath)
    }

    /// The phase's object body in the project file.
    private func phaseBody(_ project: String) throws -> String {
        let marker = try XCTUnwrap(project.range(of: "/* \(Self.phaseName) */ = {"), "the build phase exists")
        let end = try XCTUnwrap(project[marker.upperBound...].range(of: "\n\t\t};"))
        return String(project[marker.upperBound..<end.lowerBound])
    }

    /// The quoted entries of one list-valued key (`inputPaths`, `outputPaths`) in
    /// the phase body.
    private func list(_ key: String, in body: String) throws -> [String] {
        let start = try XCTUnwrap(body.range(of: "\(key) = ("))
        let close = try XCTUnwrap(body[start.upperBound...].range(of: ");"))
        return body[start.upperBound..<close.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t,\"")) }
            .filter { !$0.isEmpty }
    }

    private func declaredInputs() throws -> [String] {
        try list("inputPaths", in: try phaseBody(try pbxproj()))
    }

    private func expand(_ declared: String) -> URL {
        URL(fileURLWithPath: declared.replacingOccurrences(of: "$(SRCROOT)", with: projectDirectory.path))
            .standardized
    }

    /// Every regular file (not a symlink, not `.DS_Store`) a declared input
    /// denotes: a directory recursively, or the single file.
    private func files(of input: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "fingerprint", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(input.path)"])
        }
        guard isDirectory.boolValue else { return [input] }
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: input,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, url.lastPathComponent != ".DS_Store" { found.append(url) }
        }
        return found
    }

    private func sha256Hex<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same algorithm as the build phase, written independently: one
    /// `<sha256 of file>  <path relative to root>` line per distinct file, sorted
    /// bytewise by path, under a fixed version header; the fingerprint is the
    /// SHA-256 of that listing.
    private func recomputedFingerprint(inputs: [URL], root: URL) throws -> String {
        var lines: [String: String] = [:]
        for input in inputs {
            for file in try files(of: input) {
                let resolved = file.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(file.lastPathComponent)
                let relative = String(resolved.path.dropFirst(root.path.count + 1))
                lines[relative] = sha256Hex(try Data(contentsOf: file))
            }
        }
        let listing = lines.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\(lines[$0]!)  \($0)\n" }
            .joined()
        return sha256Hex(Data(("screenshot-qualification-fingerprint-v1\n" + listing).utf8))
    }

    private func declaredInputURLs() throws -> [URL] {
        try declaredInputs().map(expand)
    }

    // MARK: - The compiled constant equals the independently recomputed fingerprint

    func testTheCompiledGeneratedFingerprintEqualsTheIndependentlyRecomputedOne() throws {
        let recomputed = try recomputedFingerprint(inputs: try declaredInputURLs(), root: repoRoot)

        XCTAssertEqual(ScreenshotQualificationFingerprint.current, recomputed)
        XCTAssertEqual(recomputed.count, 64)
        XCTAssertTrue(recomputed.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testUnchangedSourceYieldsAnIdenticalFingerprintAndItIsIndependentOfCheckoutLocation() throws {
        let inputs = try declaredInputURLs()
        let first = try recomputedFingerprint(inputs: inputs, root: repoRoot)
        XCTAssertEqual(try recomputedFingerprint(inputs: inputs, root: repoRoot), first, "deterministic")

        // The same tree copied to a different absolute location fingerprints the same.
        let copy = try copyInputs(inputs)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        XCTAssertEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), first)
    }

    /// Copies every declared input into a temporary tree that preserves each
    /// file's path relative to the repository root.
    private func copyInputs(_ inputs: [URL]) throws -> (root: URL, inputs: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        var copied: [URL] = []
        for input in inputs {
            let relative = String(input.path.dropFirst(repoRoot.path.count + 1))
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try FileManager.default.copyItem(at: input, to: destination)
            } else {
                try Data(contentsOf: input).write(to: destination)
            }
            copied.append(destination)
        }
        return (root, copied)
    }

    // MARK: - Any change changes it

    func testChangingOneByteOfAnyOneInputChangesTheFingerprintAndRestoringItRestoresIt() throws {
        let inputs = try declaredInputURLs()
        let original = try recomputedFingerprint(inputs: inputs, root: repoRoot)
        let copy = try copyInputs(inputs)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        XCTAssertEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), original)

        // One byte of one file, for EVERY file the declared inputs cover.
        var everyFile: [URL] = []
        for input in copy.inputs { everyFile.append(contentsOf: try files(of: input)) }
        XCTAssertGreaterThan(everyFile.count, 15)
        var seen: Set<String> = [original]
        for file in everyFile {
            var bytes = try Data(contentsOf: file)
            let index = bytes.count / 2
            bytes[index] ^= 0x01
            try bytes.write(to: file)
            let changed = try recomputedFingerprint(inputs: copy.inputs, root: copy.root)
            XCTAssertNotEqual(changed, original, "a one-byte change to \(file.lastPathComponent) must change the fingerprint")
            XCTAssertTrue(seen.insert(changed).inserted, "distinct changes give distinct fingerprints")
            bytes[index] ^= 0x01
            try bytes.write(to: file)
            XCTAssertEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), original, "restoring the byte restores it")
        }
    }

    func testAddingRemovingOrRenamingAFileInTheHashedDirectoryChangesTheFingerprint() throws {
        let inputs = try declaredInputURLs()
        let original = try recomputedFingerprint(inputs: inputs, root: repoRoot)
        let copy = try copyInputs(inputs)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        let directory = copy.root.appendingPathComponent(Self.hashedDirectory)

        // A NEW file, at the top level and in a nested folder, participates with
        // no registration anywhere.
        let added = directory.appendingPathComponent("ScreenshotNewShared.swift")
        try Data("// new".utf8).write(to: added)
        let withAdded = try recomputedFingerprint(inputs: copy.inputs, root: copy.root)
        XCTAssertNotEqual(withAdded, original)
        let nested = directory.appendingPathComponent("Helper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("// helper".utf8).write(to: nested.appendingPathComponent("HelperAdapter.swift"))
        XCTAssertNotEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), withAdded)

        // An editor's `.DS_Store` never does.
        let beforeJunk = try recomputedFingerprint(inputs: copy.inputs, root: copy.root)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), beforeJunk)

        // A rename changes a path, so it changes the fingerprint.
        try FileManager.default.removeItem(at: added)
        try FileManager.default.removeItem(at: nested)
        XCTAssertEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), original)
        let runtime = directory.appendingPathComponent("ScreenshotAssistanceRuntime.swift")
        let renamed = directory.appendingPathComponent("ScreenshotAssistanceRuntime2.swift")
        try FileManager.default.moveItem(at: runtime, to: renamed)
        XCTAssertNotEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), original)
        try FileManager.default.removeItem(at: renamed)
        XCTAssertNotEqual(try recomputedFingerprint(inputs: copy.inputs, root: copy.root), original)
    }

    // MARK: - Which files participate

    func testEveryFileInTheHashedScreenshotAssistanceDirectoryParticipates() throws {
        let declared = try declaredInputs()
        XCTAssertTrue(declared.contains("$(SRCROOT)/CommonPlateios/Services/ScreenshotAssistance"), "the whole directory is declared")

        let directory = repoRoot.appendingPathComponent(Self.hashedDirectory)
        let onDisk = try files(of: directory)
        XCTAssertGreaterThan(onDisk.count, 10)
        XCTAssertTrue(onDisk.contains { $0.lastPathComponent == "ScreenshotAssistanceRuntime.swift" })
        XCTAssertTrue(onDisk.contains { $0.lastPathComponent == "RequesterOrderOutputValidator.swift" }, "nested files participate")

        var participating: Set<String> = []
        for input in try declaredInputURLs() {
            for file in try files(of: input) { participating.insert(file.path) }
        }
        for file in onDisk {
            XCTAssertTrue(participating.contains(file.path), "\(file.lastPathComponent) must participate")
        }
    }

    func testTheProductionRegistryLivesOutsideTheHashedDirectoryToAvoidSelfInvalidation() throws {
        let appDirectory = repoRoot.appendingPathComponent("ios/CommonPlateios/CommonPlateios")
        let hashed = try Set(declaredInputURLs().flatMap(files(of:)).map(\.path))
        var declarationSites: [String] = []
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            let code = ScreenshotBoundarySource.codeLines(try String(contentsOf: url, encoding: .utf8))
            if code.contains("static let production") && code.contains("ScreenshotQualificationRegistry") {
                declarationSites.append(url.path)
            }
        }
        XCTAssertEqual(declarationSites.map { ($0 as NSString).lastPathComponent }, ["ScreenshotQualificationProduction.swift"])
        for site in declarationSites {
            XCTAssertFalse(hashed.contains(site), "a registry entry pins the fingerprint, so the registry cannot be hashed into it")
        }
        XCTAssertTrue(ScreenshotQualificationRegistry.production.entries.isEmpty, "production stays empty")
        XCTAssertFalse(ScreenshotQualificationRegistry.production.admitsNonShippingProviders)
    }

    // MARK: - Dependencies outside the directory

    /// Types the hashed code refers to that are defined in app files which are
    /// NOT hashed. Each one must be justified as external-only.
    private func unhashedTypeDependencies() throws -> [String: Set<String>] {
        let appDirectory = repoRoot.appendingPathComponent("ios/CommonPlateios/CommonPlateios")
        let hashed = try Set(declaredInputURLs().flatMap(files(of:)).map(\.path))
        let declaration = try NSRegularExpression(
            pattern: #"^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|indirect|@\w+(?:\([^)]*\))?)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+(\w+)"#,
            options: [.anchorsMatchLines]
        )
        var definedIn: [String: Set<String>] = [:]
        var codeByPath: [String: String] = [:]
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = stripCommentsAndStrings(source)
            codeByPath[url.path] = code
            for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                if let range = Range(match.range(at: 1), in: code) {
                    definedIn[String(code[range]), default: []].insert(url.path)
                }
            }
        }
        let identifier = try NSRegularExpression(pattern: #"\b[A-Z]\w+\b"#)
        var dependencies: [String: Set<String>] = [:]
        for path in hashed {
            guard path.hasSuffix(".swift"), let code = codeByPath[path] else { continue }
            let range = NSRange(code.startIndex..., in: code)
            for match in identifier.matches(in: code, range: range) {
                guard let tokenRange = Range(match.range, in: code) else { continue }
                let token = String(code[tokenRange])
                guard let sites = definedIn[token], sites.isDisjoint(with: hashed) else { continue }
                dependencies[token, default: []].insert((path as NSString).lastPathComponent)
            }
        }
        return dependencies
    }

    private func stripCommentsAndStrings(_ source: String) -> String {
        var text = source
        for pattern in [#"/\*[\s\S]*?\*/"#, #"//[^\n]*"#, #""(?:\\.|[^"\\\n])*""#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    func testEveryAppTypeTheHashedCodeDependsOnIsHashedOrExplicitlyExternalOnly() throws {
        // External-only, reviewed: these are the network transport of the
        // EXTERNAL provider. External AI is not a locally qualified path, and
        // its result is re-validated by hashed on-device code before use.
        let externalOnly: Set<String> = ["ScreenshotProposalService", "ScreenshotProposalImage"]

        // `CodingKeys` is the compiler-synthesized nested name each `Codable`
        // type declares for itself, not a shared app type.
        let synthesized: Set<String> = ["CodingKeys"]

        let dependencies = try unhashedTypeDependencies()
        XCTAssertEqual(
            Set(dependencies.keys).subtracting(externalOnly).subtracting(synthesized),
            [],
            "qualification-relevant types are hashed; anything else needs an explicit external-only justification"
        )
        for token in externalOnly {
            XCTAssertEqual(dependencies[token], ["RequesterOpenAIExternalProvider.swift"], "\(token) is used only by the external adapter")
        }
        // The types that ARE qualification-relevant and live outside the
        // directory are hashed: the model/normalization/vendor dependencies.
        let declared = try declaredInputs()
        for path in [
            "Services/ScreenshotImageNormalizer.swift", "Services/ScreenshotLocalTextRecognizer.swift",
            "Models/SupportedVendorCatalog.swift", "Models/ScreenshotProposal.swift", "Models/CommonPlateModels.swift",
        ] {
            XCTAssertTrue(declared.contains("$(SRCROOT)/CommonPlateios/\(path)"), path)
        }
    }

    func testTheVendorCatalogDataTheGroundingRuleReadsIsHashed() throws {
        // `SupportedVendorCatalog` loads the bundled JSON, which is a symlink to
        // the shared catalog: the DATA that vendor grounding depends on is hashed
        // through the symlink's target, not merely the code that loads it.
        let symlink = repoRoot.appendingPathComponent("ios/CommonPlateios/CommonPlateios/Resources/SupportedVendors.json")
        let target = symlink.resolvingSymlinksInPath()
        XCTAssertEqual(target.path, repoRoot.appendingPathComponent("shared/vendors.json").path)
        XCTAssertTrue(try declaredInputs().contains("$(SRCROOT)/../../shared/vendors.json"))
        let hashedPaths = try Set(declaredInputURLs().flatMap(files(of:)).map(\.path))
        XCTAssertTrue(hashedPaths.contains(target.path))
    }

    // MARK: - The build phase is wired as declared

    func testThePhaseIsAlwaysRunBeforeSourcesAndCompilesTheGeneratedFileFromTheDerivedFileDirectory() throws {
        let project = try pbxproj()
        let body = try phaseBody(project)
        XCTAssertTrue(body.contains("alwaysOutOfDate = 1"), "an edit must always re-derive")
        XCTAssertEqual(
            try list("outputPaths", in: body),
            ["$(DERIVED_FILE_DIR)/ScreenshotQualificationFingerprint.generated.swift"]
        )

        // Before Sources in the app target.
        let target = try XCTUnwrap(project.range(of: "/* CommonPlateios */ = {\n\t\t\tisa = PBXNativeTarget;"))
        let phases = try XCTUnwrap(project[target.upperBound...].range(of: "buildPhases = ("))
        let phaseList = String(project[phases.upperBound...].prefix(400))
        let derive = try XCTUnwrap(phaseList.range(of: "/* \(Self.phaseName) */"))
        let sources = try XCTUnwrap(phaseList.range(of: "/* Sources */"))
        XCTAssertLessThan(derive.lowerBound, sources.lowerBound)

        // An explicit derived-file entry in Sources.
        XCTAssertTrue(project.contains("path = ScreenshotQualificationFingerprint.generated.swift; sourceTree = DERIVED_FILE_DIR;"))
        XCTAssertTrue(project.contains("ScreenshotQualificationFingerprint.generated.swift in Sources"))

        // Missing input fails the build; nothing is written unless it changed.
        let script = try XCTUnwrap(body.range(of: "shellScript = \""))
        let scriptText = String(body[script.upperBound...])
        XCTAssertTrue(scriptText.contains("input is missing"))
        XCTAssertTrue(scriptText.contains("input is unreadable"))
        XCTAssertTrue(scriptText.contains("has no declared inputs"))
        XCTAssertTrue(scriptText.contains("set -euo pipefail"))
        XCTAssertTrue(scriptText.contains("cat \\\"${out}\\\")\\\" = \\\"${content}\\\""), "written only when the hash changes")
    }

    func testTheGeneratedConstantIsCompiledFromTheBuildOutputNotACheckedInFile() throws {
        let appDirectory = repoRoot.appendingPathComponent("ios/CommonPlateios/CommonPlateios")
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            let code = ScreenshotBoundarySource.codeLines(try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(
                code.contains("enum ScreenshotQualificationFingerprint"),
                "\(url.lastPathComponent) must not hand-declare the generated fingerprint"
            )
        }
    }

    // MARK: - The fingerprint is part of the qualification key

    private func qualification(
        registryFingerprint: String,
        local: StubLocalProvider
    ) -> (runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>, capability: ScreenshotLocalCapability) {
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: StubExternalProvider(),
            qualification: qualifiedRegistry(implementationFingerprint: registryFingerprint, environment: environment),
            environment: environment
        )
        return (runtime, runtime.localCapability())
    }

    func testTheSameFingerprintQualifiesTheCombination() async throws {
        let local = StubLocalProvider(behavior: .output(usefulRequesterOutput))
        let (runtime, capability) = qualification(registryFingerprint: ScreenshotQualificationFingerprint.current, local: local)

        XCTAssertEqual(capability.qualification, .qualified)
        XCTAssertTrue(capability.permitsLocalAttempt)
        let evaluation = try await evaluated(runtime, try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input()])))
        guard case .completed = await runtime.runLocal(evaluation) else { return XCTFail("a matching fingerprint runs") }
        XCTAssertEqual(local.extractCallCount, 1)
    }

    func testADifferentFingerprintIsNotQualifiedAndTheProviderIsNeverQueried() async throws {
        let stale = String(repeating: "0", count: 64)
        for fingerprint in [stale, "", ScreenshotQualificationFingerprint.current + "0", String(ScreenshotQualificationFingerprint.current.dropLast())] {
            let local = StubLocalProvider(behavior: .output(usefulRequesterOutput))
            let (runtime, capability) = qualification(registryFingerprint: fingerprint, local: local)

            XCTAssertEqual(capability.qualification, .notQualified, "fingerprint `\(fingerprint)`")
            XCTAssertFalse(capability.permitsLocalAttempt)
            let evaluation = try await evaluated(runtime, try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input()])))
            guard case .localUnavailable(nil) = await runtime.runLocal(evaluation) else {
                return XCTFail("a changed implementation must fail closed")
            }
            XCTAssertEqual(local.extractCallCount, 0, "the provider is never invoked")
            XCTAssertEqual(local.availabilityCallCount, 1, "only the capability probe asked; runLocal did not ask again")
        }
    }

    func testAChangedFingerprintDoesNotAskTheProviderForAvailabilityWhenRunning() async throws {
        let local = StubLocalProvider(behavior: .output(usefulRequesterOutput))
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: StubExternalProvider(),
            qualification: qualifiedRegistry(implementationFingerprint: "stale-fingerprint", environment: environment),
            environment: environment
        )
        let evaluation = try await evaluated(runtime, try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input()])))

        _ = await runtime.runLocal(evaluation)

        XCTAssertEqual(local.availabilityCallCount, 0, "not even availability is queried for an unqualified combination")
        XCTAssertEqual(local.extractCallCount, 0)
    }

    func testTheFingerprintIsAnIndependentComponentOfTheQualificationKey() {
        let base = ScreenshotQualificationKey(
            workflow: RequesterOrderWorkflow.identity,
            provider: StubLocalProvider.stubIdentity,
            inputMode: .ocrFlattenedText,
            implementationFingerprint: ScreenshotQualificationFingerprint.current
        )
        let changed = ScreenshotQualificationKey(
            workflow: base.workflow,
            provider: base.provider,
            inputMode: base.inputMode,
            implementationFingerprint: "another"
        )
        XCTAssertNotEqual(base, changed)
        XCTAssertEqual(Set([base, changed]).count, 2)

        // Human-readable labels alone no longer decide qualification: with the
        // SAME labels but a changed implementation the key differs.
        XCTAssertEqual(base.workflow, changed.workflow)
        XCTAssertEqual(base.provider, changed.provider)
    }

    func testTheRuntimeSuppliesTheFingerprintOnlyFromTheGeneratedConstant() throws {
        let runtime = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "\(Self.hashedDirectory)/ScreenshotAssistanceRuntime.swift",
            from: #filePath
        ))
        XCTAssertTrue(runtime.contains("implementationFingerprint: ScreenshotQualificationFingerprint.current"))
        XCTAssertEqual(runtime.components(separatedBy: "implementationFingerprint:").count - 1, 1)
        // Nothing in the app hand-builds a key with a literal fingerprint.
        let app = try ScreenshotBoundarySource.appCode(from: #filePath)
        for (file, code) in app where file != "Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift" {
            if code.contains("implementationFingerprint:"), !file.hasSuffix("ScreenshotQualification.swift") {
                XCTFail("\(file) must not construct a qualification key")
            }
        }
    }

    func testNonShippingProvidersRemainRejectedAndProductionRemainsEmptyWhateverTheFingerprint() {
        let nonShipping = StubLocalProvider.stubIdentity
        XCTAssertEqual(nonShipping.distribution, .nonShipping)
        let entry = ScreenshotQualificationEntry(
            key: ScreenshotQualificationKey(
                workflow: RequesterOrderWorkflow.identity,
                provider: nonShipping,
                inputMode: .ocrFlattenedText,
                implementationFingerprint: ScreenshotQualificationFingerprint.current
            ),
            osBand: environment.osVersion...environment.osVersion,
            deviceModelIdentifiers: [environment.modelIdentifier]
        )
        let shipped = ScreenshotQualificationRegistry(shippingEntries: [entry])
        XCTAssertTrue(shipped.entries.isEmpty, "a non-shipping provider is dropped even with the current fingerprint")
        XCTAssertEqual(shipped.qualification(for: entry.key, environment: environment), .notQualified)
        XCTAssertEqual(ScreenshotQualificationRegistry.production.qualification(for: entry.key, environment: environment), .notQualified)
        XCTAssertTrue(ScreenshotQualificationRegistry.production.entries.isEmpty)
        // The simulator never qualifies, whatever a registry holds.
        XCTAssertEqual(
            ScreenshotQualificationRegistry.injectedForTesting(entries: [entry]).qualification(
                for: entry.key,
                environment: ScreenshotDeviceEnvironment(osVersion: environment.osVersion, modelIdentifier: ScreenshotDeviceEnvironment.simulatorModelIdentifier)
            ),
            .notQualified
        )
    }
}
