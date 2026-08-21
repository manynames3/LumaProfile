import Foundation
import Testing
@testable import LumaCore

enum TestSupport {
    static func makeTemporaryDirectory(named name: String = #function) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LumaProfileTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func fixture(_ name: String, extension fileExtension: String = "txt") throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"),
            "Missing fixture \(name).\(fileExtension)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func makeExecutable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func populateRequiredArgyllTools(in directory: URL) throws {
        for tool in ArgyllTool.requiredForP0 {
            _ = try makeExecutable(named: tool.rawValue, in: directory)
        }
    }

    static func display(fingerprint: String = "synthetic-display-fingerprint") -> PhysicalDisplay {
        PhysicalDisplay(
            fingerprint: fingerprint,
            cgDisplayID: 42,
            name: "Synthetic Test Display",
            widthPixels: 3_840,
            heightPixels: 2_160,
            scale: 2,
            isMain: true,
            isMirrored: false,
            isVirtual: false,
            argyllDisplayIndex: 1,
            argyllDisplayDescription: "Synthetic Display at 0, 0, width 3840, height 2160",
            userReportedMode: "Synthetic mode metadata"
        )
    }

    static func instrument(id: String = "synthetic-i1d3") -> InstrumentDescriptor {
        InstrumentDescriptor(
            id: id,
            model: "Synthetic i1Display-family fixture",
            serialNumber: "SYNTHETIC-0001",
            capabilities: ["display", "emissive"],
            isI1D3Family: true,
            status: "Available"
        )
    }

    static func correction(at url: URL) -> DisplayCorrection {
        DisplayCorrection(
            kind: .ccss,
            name: "Synthetic WLED correction",
            sourceURL: url,
            importedURL: url,
            sha256: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            declaredDisplay: "Synthetic WLED",
            declaredInstrument: "Synthetic i1Display family",
            provenance: "Synthetic unit-test value"
        )
    }
}
