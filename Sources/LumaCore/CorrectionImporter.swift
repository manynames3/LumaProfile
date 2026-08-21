import CryptoKit
import Foundation
import Darwin

public enum CorrectionImportError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case unsupportedExtension(String)
    case fileTooLarge(actual: Int, maximum: Int)
    case malformedContent(String)
    case unsafeDestination(String)
    case invalidProvenance

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let reason): return "The correction source is invalid: \(reason)"
        case .unsupportedExtension(let ext): return "Only .ccss and .ccmx corrections are supported, not '.\(ext)'."
        case .fileTooLarge(let actual, let maximum): return "The correction is \(actual) bytes; the limit is \(maximum) bytes."
        case .malformedContent(let reason): return "The correction is malformed: \(reason)"
        case .unsafeDestination(let reason): return "The correction library location is unsafe: \(reason)"
        case .invalidProvenance: return "Correction provenance must be a short, non-empty single-line description."
        }
    }
}

public actor CorrectionImporter {
    public let destinationDirectory: URL
    public let maximumFileSize: Int

    public init(destinationDirectory: URL, maximumFileSize: Int = 4 * 1_024 * 1_024) {
        self.destinationDirectory = destinationDirectory
        self.maximumFileSize = maximumFileSize
    }

    public func importCorrection(from sourceURL: URL, provenance: String) async throws -> DisplayCorrection {
        let provenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !provenance.isEmpty,
            provenance.utf8.count <= 1_024,
            !provenance.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) })
        else { throw CorrectionImportError.invalidProvenance }

        let source = try validateSourceURL(sourceURL)
        let kind = try correctionKind(for: source)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CorrectionImportError.invalidSource("The source must be a regular file, not a directory or symbolic link.")
        }
        let reportedSize = values.fileSize ?? 0
        guard reportedSize > 0 else { throw CorrectionImportError.invalidSource("The file is empty.") }
        guard reportedSize <= maximumFileSize else {
            throw CorrectionImportError.fileTooLarge(actual: reportedSize, maximum: maximumFileSize)
        }

        let data = try Data(contentsOf: source, options: [.mappedIfSafe, .uncached])
        guard data.count <= maximumFileSize else {
            throw CorrectionImportError.fileTooLarge(actual: data.count, maximum: maximumFileSize)
        }
        guard data.count == reportedSize else {
            throw CorrectionImportError.invalidSource("The file changed while it was being imported.")
        }

        let parsed = try parse(data: data, expectedKind: kind)
        let hash = LumaSHA256.hexDigest(data)
        let destinationRoot = try prepareDestinationDirectory()
        let safeStem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
        let destination = destinationRoot.appendingPathComponent(
            "\(safeStem)-\(hash.prefix(12)).\(kind.rawValue)",
            isDirectory: false
        )
        guard isDescendant(destination, of: destinationRoot) else {
            throw CorrectionImportError.unsafeDestination("The generated filename escaped the correction library.")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            guard try existingDestination(destination, matches: hash) else {
                throw CorrectionImportError.unsafeDestination("A different file already occupies the content-addressed destination.")
            }
        } else {
            let temporary = destinationRoot.appendingPathComponent(".import-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            let linkResult = temporary.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    Darwin.link(sourcePath, destinationPath)
                }
            }
            if linkResult != 0 {
                let linkError = errno
                if linkError == EEXIST,
                   FileManager.default.fileExists(atPath: destination.path),
                   try existingDestination(destination, matches: hash)
                {
                    // A concurrent import safely published the same content first.
                } else {
                    throw CorrectionImportError.unsafeDestination(
                        "The content-addressed file could not be published (POSIX error \(linkError))."
                    )
                }
            }
        }

        let displayName = parsed.descriptor
            ?? parsed.declaredDisplay
            ?? source.deletingPathExtension().lastPathComponent
        return DisplayCorrection(
            kind: kind,
            name: displayName,
            sourceURL: source,
            importedURL: destination,
            sha256: hash,
            declaredDisplay: parsed.declaredDisplay,
            declaredInstrument: parsed.declaredInstrument,
            provenance: provenance
        )
    }

    private func existingDestination(_ url: URL, matches expectedHash: String) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return try LumaSHA256.hexDigest(of: url) == expectedHash
    }

    private func validateSourceURL(_ sourceURL: URL) throws -> URL {
        guard
            sourceURL.isFileURL,
            sourceURL.path.hasPrefix("/"),
            !sourceURL.pathComponents.contains(".."),
            !sourceURL.path.utf8.contains(0)
        else {
            throw CorrectionImportError.invalidSource("A correction must be an absolute local file URL without path traversal.")
        }
        let standardized = sourceURL.standardizedFileURL
        return standardized
    }

    private func correctionKind(for source: URL) throws -> CorrectionKind {
        switch source.pathExtension.lowercased() {
        case CorrectionKind.ccss.rawValue: return .ccss
        case CorrectionKind.ccmx.rawValue: return .ccmx
        default: throw CorrectionImportError.unsupportedExtension(source.pathExtension)
        }
    }

    private struct ParsedCorrection {
        var descriptor: String?
        var declaredDisplay: String?
        var declaredInstrument: String?
    }

    private func parse(data: Data, expectedKind: CorrectionKind) throws -> ParsedCorrection {
        guard var text = String(data: data, encoding: .utf8) else {
            throw CorrectionImportError.malformedContent("The file is not valid UTF-8/ASCII CGATS text.")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.unicodeScalars.contains(where: { scalar in
            scalar.value == 0 || (scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t")
        }) else {
            throw CorrectionImportError.malformedContent("The file contains null bytes or unsupported control characters.")
        }

        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CorrectionImportError.malformedContent("The file has no CGATS signature.")
        }
        let signature = first.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard signature == expectedKind.rawValue.uppercased() else {
            throw CorrectionImportError.malformedContent(
                "The CGATS signature '\(signature)' does not match the .\(expectedKind.rawValue) extension."
            )
        }
        for required in ["BEGIN_DATA_FORMAT", "END_DATA_FORMAT", "BEGIN_DATA", "END_DATA"] where !text.uppercased().contains(required) {
            throw CorrectionImportError.malformedContent("Missing required \(required) section marker.")
        }

        switch expectedKind {
        case .ccss:
            guard
                let bandText = keyword("SPECTRAL_BANDS", in: text),
                let bandCount = Int(bandText),
                bandCount > 0
            else {
                throw CorrectionImportError.malformedContent("A CCSS file must declare SPECTRAL_BANDS.")
            }
            let table = cgatsTable(in: text)
            guard !table.rows.isEmpty, table.fields.count >= bandCount else {
                throw CorrectionImportError.malformedContent("The CCSS data section has no complete spectral samples.")
            }
            let namedSpectralIndices = table.fields.indices.filter {
                table.fields[$0].uppercased().hasPrefix("SPEC_")
            }
            let spectralIndices = namedSpectralIndices.count == bandCount
                ? namedSpectralIndices
                : Array(table.fields.indices.suffix(bandCount))
            guard table.rows.allSatisfy({ row in
                row.count == table.fields.count && spectralIndices.allSatisfy { index in
                    row.indices.contains(index) && Double(row[index]).map { $0.isFinite } == true
                }
            }) else {
                throw CorrectionImportError.malformedContent(
                    "Each CCSS row must contain its SAMPLE_ID/metadata fields plus all \(bandCount) finite spectral values."
                )
            }
        case .ccmx:
            let table = cgatsTable(in: text)
            let matrixIndices = ["XYZ_X", "XYZ_Y", "XYZ_Z"].compactMap { field in
                table.fields.firstIndex { $0.caseInsensitiveCompare(field) == .orderedSame }
            }
            guard
                matrixIndices.count == 3,
                table.rows.count == 3,
                table.rows.allSatisfy({ row in
                    row.count == table.fields.count && matrixIndices.allSatisfy { index in
                        row.indices.contains(index) && Double(row[index]).map { $0.isFinite } == true
                    }
                })
            else {
                throw CorrectionImportError.malformedContent("A CCMX data section must contain a finite 3×3 matrix.")
            }
        }

        return ParsedCorrection(
            descriptor: keyword("DESCRIPTOR", in: text),
            declaredDisplay: keyword("DISPLAY", in: text),
            declaredInstrument: keyword("INSTRUMENT", in: text)
        )
    }

    private func cgatsTable(in text: String) -> (fields: [String], rows: [[String]]) {
        enum Section { case header, format, data, done }
        var section: Section = .header
        var fields: [String] = []
        var rows: [[String]] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            switch line.uppercased() {
            case "BEGIN_DATA_FORMAT": section = .format; continue
            case "END_DATA_FORMAT": section = .header; continue
            case "BEGIN_DATA": section = .data; continue
            case "END_DATA": section = .done; continue
            default: break
            }
            switch section {
            case .format: fields.append(contentsOf: tokenize(line))
            case .data:
                let values = tokenize(line)
                if !values.isEmpty { rows.append(values) }
            case .header, .done: continue
            }
        }
        return (fields, rows)
    }

    private func tokenize(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty {
                    values.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { values.append(current) }
        return values
    }

    private func keyword(_ name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?im)^\s*"# + escaped + #"\s+(?:\"([^\"]*)\"|(\S.*?))\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        for capture in 1...2 {
            if let valueRange = Range(match.range(at: capture), in: text) {
                let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return String(value.prefix(512)) }
            }
        }
        return nil
    }

    private func prepareDestinationDirectory() throws -> URL {
        guard
            destinationDirectory.isFileURL,
            destinationDirectory.path.hasPrefix("/"),
            !destinationDirectory.pathComponents.contains("..")
        else {
            throw CorrectionImportError.unsafeDestination("The library must be an absolute local directory.")
        }
        let standardized = destinationDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard
            FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            values.isSymbolicLink != true
        else { throw CorrectionImportError.unsafeDestination("The library path is not a directory.") }
        return standardized
    }

    private func sanitizedStem(_ original: String) -> String {
        let folded = original.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(String(scalar))
            }
            return "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return String((collapsed.isEmpty ? "correction" : collapsed).prefix(64))
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedChild = child.standardizedFileURL.resolvingSymlinksInPath()
        let parentPath = resolvedParent.path.hasSuffix("/") ? resolvedParent.path : resolvedParent.path + "/"
        return resolvedChild.path.hasPrefix(parentPath)
    }
}

enum LumaSHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
