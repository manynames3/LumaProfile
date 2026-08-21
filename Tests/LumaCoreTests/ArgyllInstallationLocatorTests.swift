import Foundation
import Testing
@testable import LumaCore

@Suite
struct ArgyllInstallationLocatorTests {
    @Test
    func testExplicitDirectoryWinsOverBundledPATHAndCommonLocations() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let explicit = root.appending(path: "explicit", directoryHint: .isDirectory)
        let bundled = root.appending(path: "bundled", directoryHint: .isDirectory)
        let path = root.appending(path: "path", directoryHint: .isDirectory)
        let common = root.appending(path: "common", directoryHint: .isDirectory)
        try TestSupport.populateRequiredArgyllTools(in: explicit)
        try TestSupport.populateRequiredArgyllTools(in: bundled)
        try TestSupport.populateRequiredArgyllTools(in: path)
        try TestSupport.populateRequiredArgyllTools(in: common)

        let result = ArgyllInstallationLocator(
            explicitDirectory: explicit,
            bundledDirectory: bundled,
            environment: ["PATH": path.path],
            commonDirectories: [common]
        ).locate()

        #expect(result.installation?.directory == explicit.standardizedFileURL)
        #expect(result.candidates.map(\.requestedDirectory) == [explicit.standardizedFileURL])
    }

    @Test
    func testBundledDirectoryWinsOverPATHAndCommonLocations() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let bundled = root.appending(path: "bundled", directoryHint: .isDirectory)
        let path = root.appending(path: "path", directoryHint: .isDirectory)
        let common = root.appending(path: "common", directoryHint: .isDirectory)
        try TestSupport.populateRequiredArgyllTools(in: bundled)
        try TestSupport.populateRequiredArgyllTools(in: path)
        try TestSupport.populateRequiredArgyllTools(in: common)

        let result = ArgyllInstallationLocator(
            bundledDirectory: bundled,
            environment: ["PATH": path.path],
            commonDirectories: [common]
        ).locate()

        #expect(result.installation?.directory == bundled.standardizedFileURL)
        #expect(result.candidates.map(\.requestedDirectory) == [bundled.standardizedFileURL])
    }

    @Test
    func testIncompleteHigherPriorityCandidateFallsThroughWithoutMixingTools() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let incomplete = root.appending(path: "incomplete", directoryHint: .isDirectory)
        let complete = root.appending(path: "complete", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        _ = try TestSupport.makeExecutable(named: ArgyllTool.spotread.rawValue, in: incomplete)
        try TestSupport.populateRequiredArgyllTools(in: complete)

        let result = ArgyllInstallationLocator(
            explicitDirectory: incomplete,
            bundledDirectory: nil,
            environment: ["PATH": complete.path],
            commonDirectories: []
        ).locate()

        #expect(result.installation?.directory == complete.standardizedFileURL)
        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].diagnostic.contains("missing:"))
        #expect(result.candidates[0].toolStatus[.spotread] == true)
        #expect(result.candidates[0].toolStatus[.dispcal] == false)
    }

    @Test
    func testSymlinkedRequiredToolsMustResolveToOneBinaryDirectory() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let facade = root.appending(path: "facade", directoryHint: .isDirectory)
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = root.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: facade, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        for (index, tool) in ArgyllTool.requiredForP0.enumerated() {
            let targetDirectory = index == 0 ? second : first
            let target = try TestSupport.makeExecutable(named: tool.rawValue, in: targetDirectory)
            try FileManager.default.createSymbolicLink(
                at: facade.appending(path: tool.rawValue),
                withDestinationURL: target
            )
        }

        let result = ArgyllInstallationLocator(
            explicitDirectory: facade,
            bundledDirectory: nil,
            environment: [:],
            commonDirectories: []
        ).locate()

        #expect(result.installation == nil)
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].resolvedDirectory == nil)
        #expect(result.candidates[0].diagnostic.contains("refusing to mix installations"))
    }

    @Test
    func testNonExecutableFileDoesNotSatisfyRequiredTool() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        try TestSupport.populateRequiredArgyllTools(in: root)
        let tool = root.appending(path: ArgyllTool.profcheck.rawValue)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)

        let result = ArgyllInstallationLocator(
            explicitDirectory: root,
            bundledDirectory: nil,
            environment: [:],
            commonDirectories: []
        ).locate()

        #expect(result.installation == nil)
        #expect(result.candidates[0].toolStatus[.profcheck] == false)
        #expect(result.candidates[0].diagnostic.contains("profcheck"))
    }

    @Test
    func testMissingDispwinRejectsOtherwiseCompleteCandidate() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        for tool in ArgyllTool.requiredForP0 where tool != .dispwin {
            _ = try TestSupport.makeExecutable(named: tool.rawValue, in: root)
        }

        let result = ArgyllInstallationLocator(
            explicitDirectory: root,
            bundledDirectory: nil,
            environment: [:],
            commonDirectories: []
        ).locate()

        #expect(result.installation == nil)
        #expect(result.candidates[0].toolStatus[.dispwin] == false)
        #expect(result.candidates[0].diagnostic.contains("dispwin"))
    }

    @Test
    func testXiccluIsReportedButNotRequiredForP0() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        try TestSupport.populateRequiredArgyllTools(in: root)

        let result = ArgyllInstallationLocator(
            explicitDirectory: root,
            bundledDirectory: nil,
            environment: [:],
            commonDirectories: []
        ).locate()

        let installation = try #require(result.installation)
        #expect(!(result.candidates[0].toolStatus[.xicclu] ?? true))
        do {
            _ = try installation.executable(for: .xicclu)
            Issue.record("Expected missing optional tool")
        } catch ArgyllEngineError.missingTool(.xicclu) {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testPATHDeduplicatesStandardizedAbsoluteDirectoriesAndIgnoresRelativeEntries() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }

        let result = ArgyllInstallationLocator(
            bundledDirectory: nil,
            environment: ["PATH": "relative:\(root.path):\(root.path)/./"],
            commonDirectories: [root]
        ).locate()

        #expect(result.candidates.map(\.requestedDirectory) == [root.standardizedFileURL])
    }

    @Test
    func testVersionParsingFormattingAndOrdering() throws {
        #expect(ArgyllVersion("Argyll CMS Version 3.5.0")?.description == "3.5.0")
        #expect(ArgyllVersion("V2.3")?.description == "2.3.0")
        #expect(ArgyllVersion("3.4.1_beta2") == ArgyllVersion(major: 3, minor: 4, patch: 1, suffix: "_beta2"))
        #expect(ArgyllVersion("version unknown") == nil)
        #expect(ArgyllVersion(major: 3, minor: 4, patch: 9) < ArgyllVersion(major: 3, minor: 5))
    }
}
