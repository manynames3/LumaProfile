import Foundation
import Testing
@testable import LumaCore

@Suite
struct CorrectionImporterTests {
    @Test
    func importsSyntheticCCSSWithSampleIDMetadataHashAndRestrictivePermissions() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let source = root.appending(path: "incoming/synthetic-sample-id.ccss")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try TestSupport.fixture("correction-sample-id.synthetic", extension: "ccss")
        try Data(fixture.utf8).write(to: source)
        let destination = root.appending(path: "library", directoryHint: .isDirectory)
        let importer = CorrectionImporter(destinationDirectory: destination)

        let correction = try await importer.importCorrection(
            from: source,
            provenance: "  Synthetic fixture authored for unit tests  "
        )

        #expect(correction.kind == .ccss)
        #expect(correction.name == "Synthetic WLED SAMPLE_ID correction")
        #expect(correction.declaredDisplay == "Synthetic WLED panel")
        #expect(correction.declaredInstrument == "Synthetic i1Display family")
        #expect(correction.provenance == "Synthetic fixture authored for unit tests")
        #expect(correction.sha256.count == 64)
        #expect(correction.importedURL.deletingLastPathComponent() == destination)
        #expect(correction.importedURL.lastPathComponent.contains(String(correction.sha256.prefix(12))))
        #expect(try Data(contentsOf: correction.importedURL) == Data(fixture.utf8))
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: correction.importedURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test
    func repeatedImportIsContentAddressedAndDoesNotRewriteAnotherPath() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let source = root.appending(path: "synthetic.ccss")
        try Data(try TestSupport.fixture("correction-sample-id.synthetic", extension: "ccss").utf8).write(to: source)
        let importer = CorrectionImporter(destinationDirectory: root.appending(path: "library"))

        let first = try await importer.importCorrection(from: source, provenance: "Synthetic first import")
        let second = try await importer.importCorrection(from: source, provenance: "Synthetic second import")

        #expect(first.sha256 == second.sha256)
        #expect(first.importedURL == second.importedURL)
        #expect(first.id != second.id)
        #expect(second.provenance == "Synthetic second import")
    }

    @Test
    func rejectsExtensionSignatureMismatchSymlinkOversizeAndInvalidProvenance() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let data = Data(try TestSupport.fixture("correction-sample-id.synthetic", extension: "ccss").utf8)
        let mismatched = root.appending(path: "mismatch.ccmx")
        try data.write(to: mismatched)
        let importer = CorrectionImporter(destinationDirectory: root.appending(path: "library"))

        do {
            _ = try await importer.importCorrection(from: mismatched, provenance: "Synthetic mismatch")
            Issue.record("Expected signature/extension mismatch rejection")
        } catch CorrectionImportError.malformedContent(let reason) {
            #expect(reason.contains("does not match"))
        }

        let source = root.appending(path: "source.ccss")
        try data.write(to: source)
        let link = root.appending(path: "link.ccss")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try await importer.importCorrection(from: link, provenance: "Synthetic link")
            Issue.record("Expected symlink rejection")
        } catch CorrectionImportError.invalidSource(let reason) {
            #expect(reason.lowercased().contains("symbolic"))
        }

        let tinyImporter = CorrectionImporter(
            destinationDirectory: root.appending(path: "small-library"),
            maximumFileSize: data.count - 1
        )
        do {
            _ = try await tinyImporter.importCorrection(from: source, provenance: "Synthetic oversize")
            Issue.record("Expected size rejection")
        } catch CorrectionImportError.fileTooLarge(let actual, let maximum) {
            #expect(actual == data.count)
            #expect(maximum == data.count - 1)
        }

        do {
            _ = try await importer.importCorrection(from: source, provenance: "line one\nline two")
            Issue.record("Expected invalid provenance rejection")
        } catch CorrectionImportError.invalidProvenance {
            // Expected.
        }
    }
}
