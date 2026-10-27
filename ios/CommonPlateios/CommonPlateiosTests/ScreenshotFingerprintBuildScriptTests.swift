//
//  ScreenshotFingerprintBuildScriptTests.swift
//  CommonPlateiosTests
//
// W4-S3 review fix (D2): proof about the ACTUAL "Derive Screenshot Qualification
// Fingerprint" build-phase script, not a Swift reimplementation of it. The test
// reads the script text out of the project file, runs it with /bin/bash under a
// minimal environment (the tools Xcode's script sandbox would leave it), against
// throwaway source trees, and inspects the constant it writes.
//
// The property under test: every relevant input file is included EXACTLY ONCE
// and a path is an opaque filename — spaces, tabs, and names that differ only
// after a shared whitespace-containing prefix cannot split, merge, or drop an
// entry — with a deterministic order and hard failure on any read error.
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotFingerprintBuildScriptTests: XCTestCase {
    // MARK: - Running the real script

    private struct RunResult {
        let status: Int32
        let stderr: String
        /// The fingerprint written to the output file, if any.
        let fingerprint: String?
    }

    private var scriptText: String {
        get throws {
            let project = try ScreenshotBoundarySource.read(
                "ios/CommonPlateios/CommonPlateios.xcodeproj/project.pbxproj",
                from: #filePath
            )
            let marker = try XCTUnwrap(project.range(of: "/* Derive Screenshot Qualification Fingerprint */ = {"))
            let body = project[marker.upperBound...]
            let start = try XCTUnwrap(body.range(of: "shellScript = \""))
            var escaped = ""
            var index = start.upperBound
            scan: while index < body.endIndex {
                let character = body[index]
                switch character {
                case "\\":
                    index = body.index(after: index)
                    switch body[index] {
                    case "n": escaped.append("\n")
                    case "t": escaped.append("\t")
                    default: escaped.append(body[index])
                    }
                case "\"":
                    break scan
                default:
                    escaped.append(character)
                }
                index = body.index(after: index)
            }
            return escaped
        }
    }

    /// Runs the phase script exactly as Xcode would (`/bin/bash`, declared inputs
    /// as `SCRIPT_INPUT_FILE_n`), and reads the constant it wrote.
    private func runScript(
        srcRoot: URL,
        inputs: [String],
        output: URL,
        targetTemp: URL
    ) throws -> RunResult {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "SRCROOT": srcRoot.path,
            "TARGET_TEMP_DIR": targetTemp.path,
            "SCRIPT_OUTPUT_FILE_0": output.path,
            "SCRIPT_INPUT_FILE_COUNT": String(inputs.count),
        ]
        for (index, input) in inputs.enumerated() { environment["SCRIPT_INPUT_FILE_\(index)"] = input }

        var errorPipe: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&errorPipe), 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, errorPipe[0])
        posix_spawn_file_actions_addclose(&actions, errorPipe[1])

        let argv: [String] = ["/bin/bash", "-c", try scriptText]
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/bash", &actions, nil, &cArgv, &cEnvp)
        XCTAssertEqual(spawned, 0, "could not spawn /bin/bash")
        close(errorPipe[1])
        let errorData = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1

        var fingerprint: String?
        if let written = try? String(contentsOf: output, encoding: .utf8),
           let range = written.range(of: #"current = "[0-9a-f]{64}""#, options: .regularExpression) {
            fingerprint = String(written[range].dropFirst("current = \"".count).dropLast())
        }
        return RunResult(status: exitCode, stderr: String(decoding: errorData, as: UTF8.self), fingerprint: fingerprint)
    }

    // MARK: - A throwaway source tree shaped like the repository

    private struct Tree {
        let root: URL
        var srcRoot: URL { root.appendingPathComponent("ios/CommonPlateios") }
        var sources: URL { srcRoot.appendingPathComponent("src") }
        var shared: URL { root.appendingPathComponent("shared") }
        var targetTemp: URL { root.appendingPathComponent("target-temp") }
        var output: URL { root.appendingPathComponent("out/Generated.swift") }

        func write(_ name: String, _ content: String, under directory: URL? = nil) throws {
            let file = (directory ?? sources).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
    }

    private func makeTree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-script-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let tree = Tree(root: root)
        for directory in [tree.sources, tree.shared, tree.targetTemp, tree.output.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return tree
    }

    /// The default declared inputs: the source directory and one shared file.
    private func inputs(_ tree: Tree, extra: [String] = []) -> [String] {
        [tree.sources.path, tree.shared.appendingPathComponent("catalog.json").path] + extra
    }

    private func fingerprint(_ tree: Tree, extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try runScript(srcRoot: tree.srcRoot, inputs: inputs(tree, extra: extra), output: tree.output, targetTemp: tree.targetTemp)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        return try XCTUnwrap(result.fingerprint, "the script wrote no fingerprint", file: file, line: line)
    }

    private func populate(_ tree: Tree) throws {
        try tree.write("Top.swift", "top")
        try tree.write("My Dir/x y one.swift", "one")
        try tree.write("My Dir/x y two.swift", "two")
        try tree.write("My Dir/a\tb.swift", "tab")
        try tree.write("catalog.json", "{}", under: tree.shared)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The listing algorithm, independently: hash of `<sha256>  <relative path>\n`
    /// lines sorted bytewise by relative path, under the version header.
    private func expected(_ tree: Tree, extraFiles: [URL] = []) throws -> String {
        var entries: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: tree.sources, includingPropertiesForKeys: [.isRegularFileKey]))
        var files = [tree.shared.appendingPathComponent("catalog.json")] + extraFiles
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append(url)
        }
        for file in files where file.lastPathComponent != ".DS_Store" {
            let relative = String(file.path.dropFirst(tree.root.path.count + 1))
            entries[relative] = try Data(contentsOf: file)
        }
        let listing = entries.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\(sha256Hex(entries[$0]!))  \($0)\n" }
            .joined()
        return sha256Hex(Data(("screenshot-qualification-fingerprint-v1\n" + listing).utf8))
    }

    // MARK: - The real inputs

    func testTheActualScriptOnTheRealDeclaredInputsProducesTheCompiledFingerprint() throws {
        let repo = ScreenshotBoundarySource.root(from: #filePath).resolvingSymlinksInPath()
        let project = repo.appendingPathComponent("ios/CommonPlateios")
        let declared = try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios.xcodeproj/project.pbxproj", from: #filePath
        )
        let marker = try XCTUnwrap(declared.range(of: "/* Derive Screenshot Qualification Fingerprint */ = {"))
        let inputBlock = try XCTUnwrap(declared[marker.upperBound...].range(of: "inputPaths = ("))
        let close = try XCTUnwrap(declared[inputBlock.upperBound...].range(of: ");"))
        let inputs = declared[inputBlock.upperBound..<close.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t,\"")) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "$(SRCROOT)", with: project.path) }
            .map { URL(fileURLWithPath: $0).standardized.path }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-real-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try runScript(
            srcRoot: project, inputs: inputs, output: scratch.appendingPathComponent("Generated.swift"), targetTemp: scratch
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.fingerprint, ScreenshotQualificationFingerprint.current)
    }

    // MARK: - Determinism and the independent algorithm

    func testUnchangedTreeYieldsAnIdenticalFingerprintThatMatchesTheIndependentListingHash() throws {
        let tree = try makeTree()
        try populate(tree)

        let first = try fingerprint(tree)
        XCTAssertEqual(try fingerprint(tree), first, "deterministic")
        XCTAssertEqual(first, try expected(tree), "the script and the independent algorithm agree, odd filenames included")
    }

    func testTheScriptWritesTheGeneratedFileOnlyWhenTheHashChanges() throws {
        let tree = try makeTree()
        try populate(tree)
        _ = try fingerprint(tree)
        let firstWrite = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: tree.output.path)[.modificationDate] as? Date)
        Thread.sleep(forTimeInterval: 1.1)

        _ = try fingerprint(tree)
        let unchanged = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: tree.output.path)[.modificationDate] as? Date)
        XCTAssertEqual(unchanged, firstWrite, "an unchanged tree does not rewrite the file")

        try tree.write("Top.swift", "top changed")
        _ = try fingerprint(tree)
        let changed = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: tree.output.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(changed, firstWrite)
    }

    // MARK: - Filenames are opaque

    func testTwoFilesSharingAWhitespaceContainingPrefixAreBothIncludedExactlyOnce() throws {
        let tree = try makeTree()
        try populate(tree)
        let both = try fingerprint(tree)

        // Each one independently affects the fingerprint: neither was collapsed
        // into the other by a whitespace-field sort key.
        try tree.write("My Dir/x y one.swift", "one CHANGED")
        let changedFirst = try fingerprint(tree)
        XCTAssertNotEqual(changedFirst, both)
        try tree.write("My Dir/x y one.swift", "one")
        try tree.write("My Dir/x y two.swift", "two CHANGED")
        let changedSecond = try fingerprint(tree)
        XCTAssertNotEqual(changedSecond, both)
        XCTAssertNotEqual(changedSecond, changedFirst)
        try tree.write("My Dir/x y two.swift", "two")

        // Removing either one changes it, and they differ from each other.
        try FileManager.default.removeItem(at: tree.sources.appendingPathComponent("My Dir/x y two.swift"))
        let withoutSecond = try fingerprint(tree)
        try tree.write("My Dir/x y two.swift", "two")
        try FileManager.default.removeItem(at: tree.sources.appendingPathComponent("My Dir/x y one.swift"))
        let withoutFirst = try fingerprint(tree)
        XCTAssertEqual(Set([both, withoutSecond, withoutFirst]).count, 3)
        XCTAssertEqual(withoutFirst, try expected(tree))
    }

    func testPathsWithSpacesAndTabsParticipateAndTheirNamesAreNotSplit() throws {
        let tree = try makeTree()
        try populate(tree)
        let original = try fingerprint(tree)

        try tree.write("My Dir/a\tb.swift", "tab CHANGED")
        XCTAssertNotEqual(try fingerprint(tree), original, "a tab-named file participates")
        try tree.write("My Dir/a\tb.swift", "tab")

        // A leading-space directory and a name with several internal spaces.
        try tree.write(" lead/two  spaces  here.swift", "s")
        let withSpaces = try fingerprint(tree)
        XCTAssertNotEqual(withSpaces, original)
        XCTAssertEqual(withSpaces, try expected(tree))
        try tree.write(" lead/two  spaces  here.swift", "t")
        XCTAssertNotEqual(try fingerprint(tree), withSpaces)
    }

    // MARK: - Add, remove, rename, one byte

    func testAddRemoveRenameAndOneByteChangesEachChangeTheFingerprintAndRestoringRestoresIt() throws {
        let tree = try makeTree()
        try populate(tree)
        let original = try fingerprint(tree)

        try tree.write("Added File.swift", "new")
        let added = try fingerprint(tree)
        XCTAssertNotEqual(added, original)
        try FileManager.default.removeItem(at: tree.sources.appendingPathComponent("Added File.swift"))
        XCTAssertEqual(try fingerprint(tree), original, "removing the added file restores it")

        try FileManager.default.removeItem(at: tree.sources.appendingPathComponent("Top.swift"))
        let removed = try fingerprint(tree)
        XCTAssertNotEqual(removed, original)
        try tree.write("Top.swift", "top")
        XCTAssertEqual(try fingerprint(tree), original)

        try FileManager.default.moveItem(
            at: tree.sources.appendingPathComponent("My Dir/x y one.swift"),
            to: tree.sources.appendingPathComponent("My Dir/x y uno.swift")
        )
        let renamed = try fingerprint(tree)
        XCTAssertNotEqual(renamed, original, "a rename changes a path")
        XCTAssertNotEqual(renamed, removed)
        try FileManager.default.moveItem(
            at: tree.sources.appendingPathComponent("My Dir/x y uno.swift"),
            to: tree.sources.appendingPathComponent("My Dir/x y one.swift")
        )
        XCTAssertEqual(try fingerprint(tree), original)

        var bytes = try Data(contentsOf: tree.sources.appendingPathComponent("Top.swift"))
        bytes[0] ^= 0x01
        try bytes.write(to: tree.sources.appendingPathComponent("Top.swift"))
        XCTAssertNotEqual(try fingerprint(tree), original, "one byte")
        bytes[0] ^= 0x01
        try bytes.write(to: tree.sources.appendingPathComponent("Top.swift"))
        XCTAssertEqual(try fingerprint(tree), original)

        // The shared (outside-the-directory) input participates too.
        try tree.write("catalog.json", "{ }", under: tree.shared)
        XCTAssertNotEqual(try fingerprint(tree), original)
    }

    // MARK: - Exactly once

    func testAnInputNamedTwiceIsIncludedExactlyOnce() throws {
        let tree = try makeTree()
        try populate(tree)
        let once = try fingerprint(tree)

        // The same directory again, and a file already inside it, as explicit inputs.
        let twice = try fingerprint(tree, extra: [tree.sources.path, tree.sources.appendingPathComponent("My Dir/x y one.swift").path])

        XCTAssertEqual(twice, once)
    }

    func testXcodesOwnGeneratedScriptInputIsNotHashed() throws {
        let tree = try makeTree()
        try populate(tree)
        let plain = try fingerprint(tree)
        try Data("machine specific".utf8).write(to: tree.targetTemp.appendingPathComponent("Script-1234.sh"))

        let withXcodeScript = try fingerprint(tree, extra: [tree.targetTemp.appendingPathComponent("Script-1234.sh").path])

        XCTAssertEqual(withXcodeScript, plain)
    }

    func testTheFingerprintIsIndependentOfWhereTheTreeIsCheckedOut() throws {
        let first = try makeTree()
        let second = try makeTree()
        for tree in [first, second] { try populate(tree) }
        XCTAssertEqual(try fingerprint(first), try fingerprint(second))
    }

    // MARK: - Hard failures

    func testAMissingInputFailsTheBuildAndWritesNothing() throws {
        let tree = try makeTree()
        try populate(tree)
        let result = try runScript(
            srcRoot: tree.srcRoot,
            inputs: inputs(tree, extra: [tree.sources.appendingPathComponent("Does Not Exist.swift").path]),
            output: tree.output,
            targetTemp: tree.targetTemp
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("input is missing"), result.stderr)
        XCTAssertNil(result.fingerprint)
    }

    func testAnUnreadableFileFailsTheBuildAndLeavesThePreviousOutputUntouched() throws {
        let tree = try makeTree()
        try populate(tree)
        let good = try fingerprint(tree)
        let locked = tree.sources.appendingPathComponent("My Dir/x y two.swift")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let result = try runScript(srcRoot: tree.srcRoot, inputs: inputs(tree), output: tree.output, targetTemp: tree.targetTemp)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("input is unreadable"), result.stderr)
        XCTAssertEqual(result.fingerprint, good, "the previously generated constant was not replaced by a partial hash")
    }

    func testAnEmptyDeclaredDirectoryAndNoInputsFailTheBuild() throws {
        let tree = try makeTree()
        try populate(tree)
        let empty = tree.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyResult = try runScript(srcRoot: tree.srcRoot, inputs: [empty.path], output: tree.output, targetTemp: tree.targetTemp)
        XCTAssertNotEqual(emptyResult.status, 0)
        XCTAssertTrue(emptyResult.stderr.contains("has no files"), emptyResult.stderr)

        let none = try runScript(srcRoot: tree.srcRoot, inputs: [], output: tree.output, targetTemp: tree.targetTemp)
        XCTAssertNotEqual(none.status, 0)
        XCTAssertTrue(none.stderr.contains("no declared inputs"), none.stderr)
    }

    func testAFilenameContainingANewlineIsRejectedRatherThanAllowedToForgeAListingLine() throws {
        let tree = try makeTree()
        try populate(tree)
        try tree.write("bad\nname.swift", "x")

        let result = try runScript(srcRoot: tree.srcRoot, inputs: inputs(tree), output: tree.output, targetTemp: tree.targetTemp)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("contains a newline"), result.stderr)
    }
}
