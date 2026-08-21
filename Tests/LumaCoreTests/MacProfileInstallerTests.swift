import Foundation
import Testing
@testable import LumaCore

@Suite
struct MacProfileInstallerTests {
    @Test
    func profileURLLookupDistinguishesNoAssociationFromRetrievalFailure() throws {
        let expected = URL(fileURLWithPath: "/synthetic/current.icc")

        #expect(try MacProfileInstaller.checkedProfileURL(expected, failureDescription: nil) == expected)
        #expect(try MacProfileInstaller.checkedProfileURL(nil, failureDescription: nil) == nil)

        do {
            _ = try MacProfileInstaller.checkedProfileURL(
                nil,
                failureDescription: "Synthetic ColorSync retrieval failure"
            )
            Issue.record("Expected a ColorSync URL retrieval failure")
        } catch ProfileInstallerError.currentProfileLookupFailed(let detail) {
            #expect(detail == "Synthetic ColorSync retrieval failure")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func cleanupOwnershipAcceptsOnlyDirectGeneratedRegularICCFiles() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let profileDirectory = root.appending(path: "ColorSync/Profiles/LumaProfile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let owned = profileDirectory.appending(path: "Studio-Display-A1b2C3d4.icc")
        try Data("synthetic profile placeholder".utf8).write(to: owned)
        #expect(MacProfileInstaller.isOwnedInstalledCandidate(owned, in: profileDirectory))

        let foreignName = profileDirectory.appending(path: "Unrelated.icc")
        try Data("synthetic unrelated profile".utf8).write(to: foreignName)
        #expect(!MacProfileInstaller.isOwnedInstalledCandidate(foreignName, in: profileDirectory))

        let wrongExtension = profileDirectory.appending(path: "Studio-Display-A1b2C3d4.icm")
        try Data("synthetic profile placeholder".utf8).write(to: wrongExtension)
        #expect(!MacProfileInstaller.isOwnedInstalledCandidate(wrongExtension, in: profileDirectory))

        let nestedDirectory = profileDirectory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nested = nestedDirectory.appending(path: "Studio-Display-A1b2C3d4.icc")
        try Data("synthetic profile placeholder".utf8).write(to: nested)
        #expect(!MacProfileInstaller.isOwnedInstalledCandidate(nested, in: profileDirectory))

        let outside = root.appending(path: "Studio-Display-A1b2C3d4.icc")
        try Data("synthetic profile placeholder".utf8).write(to: outside)
        #expect(!MacProfileInstaller.isOwnedInstalledCandidate(outside, in: profileDirectory))

        let symlink = profileDirectory.appending(path: "Linked-A1b2C3d4.icc")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        #expect(!MacProfileInstaller.isOwnedInstalledCandidate(symlink, in: profileDirectory))

        #expect(MacProfileInstaller.removeOwnedInstalledCandidate(
            owned,
            from: profileDirectory,
            fileManager: .default
        ))
        #expect(!FileManager.default.fileExists(atPath: owned.path))

        #expect(!MacProfileInstaller.removeOwnedInstalledCandidate(
            foreignName,
            from: profileDirectory,
            fileManager: .default
        ))
        #expect(FileManager.default.fileExists(atPath: foreignName.path))
    }
}
