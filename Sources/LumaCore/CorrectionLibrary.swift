import Foundation

public enum CorrectionLibraryError: LocalizedError, Sendable {
    case unsupportedType
    case emptyFile
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: "Choose a CCSS or CCMX correction file."
        case .emptyFile: "The correction file is empty."
        case .fileTooLarge: "The correction file is unexpectedly large and was not imported."
        }
    }
}

public actor CorrectionLibrary {
    public let rootDirectory: URL
    private let fileManager: FileManager
    private let indexURL: URL
    private let importer: CorrectionImporter

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaProfile/Corrections", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.rootDirectory = resolvedRoot
        self.indexURL = resolvedRoot.appending(path: "index.json")
        self.importer = CorrectionImporter(destinationDirectory: resolvedRoot)
    }

    public func list() async throws -> [DisplayCorrection] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DisplayCorrection].self, from: Data(contentsOf: indexURL))
            .sorted { $0.importedAt > $1.importedAt }
    }

    public func importFile(at sourceURL: URL) async throws -> DisplayCorrection {
        let correction = try await importer.importCorrection(
            from: sourceURL,
            provenance: "Imported from \(sourceURL.lastPathComponent)"
        )
        var corrections = (try? await list()) ?? []
        corrections.removeAll { $0.sha256 == correction.sha256 }
        corrections.append(correction)
        try save(corrections)
        return correction
    }

    public func remove(_ correction: DisplayCorrection) async throws {
        var corrections = try await list()
        corrections.removeAll { $0.id == correction.id }
        try save(corrections)
        if correction.importedURL.deletingLastPathComponent().standardizedFileURL == rootDirectory.standardizedFileURL {
            try? fileManager.removeItem(at: correction.importedURL)
        }
    }

    private func save(_ corrections: [DisplayCorrection]) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(corrections).write(to: indexURL, options: [.atomic])
    }
}
