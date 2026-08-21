import Foundation

public enum ArgyllVersionParser {
    public static func parse(_ rawOutput: String) -> ArgyllVersion? {
        let patterns = [
            #"Argyll(?:CMS)?(?:\s+CMS)?(?:\s+Version|\s+version|\s+V)?\s*[:=]?\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z0-9._-]*)"#,
            #"(?:spotread|dispcal|targen|dispread|colprof|profcheck)\s+(?:version\s*)?([0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z0-9._-]*)"#,
            #"(?:^|[\r\n])(?:Measure spot values|Calibrate a Display|Generate Target deviceb test chart color values|Read a Display|Create ICC profile|Check accuracy of ICC profile),\s*Version\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z0-9._-]*)"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(rawOutput.startIndex..<rawOutput.endIndex, in: rawOutput)
            guard
                let match = expression.firstMatch(in: rawOutput, range: range),
                let versionRange = Range(match.range(at: 1), in: rawOutput)
            else { continue }
            return ArgyllVersion(String(rawOutput[versionRange]))
        }
        return nil
    }
}

public enum ArgyllParserCompatibility {
    public static func validate(_ version: ArgyllVersion?, parser: String, rawOutput: String) throws {
        guard let version else { return }
        guard (1...3).contains(version.major) else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: parser,
                version: version,
                excerpt: excerpt(rawOutput)
            )
        }
    }

    static func excerpt(_ rawOutput: String) -> String {
        let normalized = rawOutput.replacingOccurrences(of: "\0", with: "�")
        return String(normalized.prefix(512))
    }
}

public struct ArgyllInstrumentListParseResult: Sendable {
    public var instruments: [InstrumentDescriptor]
    public var rawOutput: String
    public var detectedVersion: ArgyllVersion?
    public var parserVersion: Int

    public init(
        instruments: [InstrumentDescriptor],
        rawOutput: String,
        detectedVersion: ArgyllVersion?,
        parserVersion: Int = 1
    ) {
        self.instruments = instruments
        self.rawOutput = rawOutput
        self.detectedVersion = detectedVersion
        self.parserVersion = parserVersion
    }
}

public enum ArgyllInstrumentListParser {
    public static func parse(
        _ rawOutput: String,
        version: ArgyllVersion? = nil
    ) throws -> ArgyllInstrumentListParseResult {
        let detectedVersion = version ?? ArgyllVersionParser.parse(rawOutput)
        try ArgyllParserCompatibility.validate(
            detectedVersion,
            parser: "instrument-list-v1",
            rawOutput: rawOutput
        )

        var inInstrumentSection = false
        var sawInstrumentSection = false
        var descriptors: [InstrumentDescriptor] = []

        for rawLine in rawOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.contains("-c")
                && (lower.contains("instrument") || lower.contains("communication port") || lower.contains("com port"))
            {
                inInstrumentSection = true
                sawInstrumentSection = true
                continue
            }
            if inInstrumentSection, line.hasPrefix("-"), !lower.contains("-c") {
                inInstrumentSection = false
            }

            if let entry = numberedEntry(line), inInstrumentSection || looksLikeInstrument(entry.name) {
                descriptors.append(descriptor(id: entry.id, name: entry.name, trailing: entry.trailing))
                continue
            }

            if lower.hasPrefix("instrument type"), let separator = line.firstIndex(of: ":") {
                let model = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                if !model.isEmpty {
                    descriptors.append(descriptor(id: "1", name: model, trailing: line))
                }
            }
        }

        var unique: [InstrumentDescriptor] = []
        var seen = Set<String>()
        for descriptor in descriptors where seen.insert(descriptor.id).inserted {
            unique.append(descriptor)
        }
        unique.sort { (Int($0.id) ?? .max) < (Int($1.id) ?? .max) }

        if unique.isEmpty,
           !rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !sawInstrumentSection,
           !containsNoInstrumentMessage(rawOutput)
        {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "instrument-list-v1",
                version: detectedVersion,
                excerpt: ArgyllParserCompatibility.excerpt(rawOutput)
            )
        }

        return ArgyllInstrumentListParseResult(
            instruments: unique,
            rawOutput: rawOutput,
            detectedVersion: detectedVersion
        )
    }

    private static func descriptor(id: String, name: String, trailing: String) -> InstrumentDescriptor {
        let isI1D3 = isI1D3Family(name)
        var capabilities = ["display-emission"]
        if isI1D3 {
            capabilities += ["colorimeter", "CCSS", "CCMX", "refresh-override"]
        }
        return InstrumentDescriptor(
            id: id,
            model: name,
            serialNumber: serialNumber(in: "\(name) \(trailing)"),
            capabilities: capabilities,
            isI1D3Family: isI1D3,
            status: isI1D3 ? "Supported i1D3-family instrument" : "Detected; support is not validated"
        )
    }

    private static func isI1D3Family(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return normalized.contains("i1d3")
            || normalized.contains("i1 display")
            || normalized.contains("i1display")
            || normalized.contains("colormunki display")
            || normalized.contains("colorchecker display")
            || normalized.contains("calibrite display")
    }

    private static func looksLikeInstrument(_ value: String) -> Bool {
        let lower = value.lowercased()
        return [
            "x-rite", "xrite", "i1", "calibrite", "colorchecker", "colormunki",
            "spyder", "datacolor", "jeti", "klein", "dtp", "spectrolino", "colorhug",
        ].contains { lower.contains($0) }
    }

    private static func serialNumber(in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"serial(?:\s+number)?\s*[:#=]?\s*([A-Za-z0-9][A-Za-z0-9._-]{2,})"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = expression.firstMatch(in: value, range: range),
            let serialRange = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[serialRange])
    }

    private static func containsNoInstrumentMessage(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("no instrument")
            || lower.contains("no device")
            || lower.contains("no usb")
            || lower.contains("not found")
    }
}

public struct ArgyllDisplayDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var description: String
    public var rawLine: String

    public init(index: Int, description: String, rawLine: String) {
        self.index = index
        self.description = description
        self.rawLine = rawLine
    }
}

public enum ArgyllDisplayListParser {
    public static func parse(_ rawOutput: String, version: ArgyllVersion? = nil) throws -> [ArgyllDisplayDescriptor] {
        try ArgyllParserCompatibility.validate(
            version ?? ArgyllVersionParser.parse(rawOutput),
            parser: "display-list-v1",
            rawOutput: rawOutput
        )
        var inDisplaySection = false
        var displays: [ArgyllDisplayDescriptor] = []
        for rawLine in rawOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.contains("-d") && lower.contains("display") && lower.contains("choose") {
                inDisplaySection = true
                continue
            }
            if inDisplaySection, line.hasPrefix("-"), !lower.contains("-d") {
                inDisplaySection = false
            }
            guard inDisplaySection, let entry = numberedEntry(line), let index = Int(entry.id) else { continue }
            displays.append(ArgyllDisplayDescriptor(index: index, description: entry.name, rawLine: rawLine))
        }
        var seen = Set<Int>()
        return displays.filter { seen.insert($0.index).inserted }.sorted { $0.index < $1.index }
    }
}

public struct ArgyllSpotMeasurementParseResult: Sendable {
    public var measurement: Measurement
    public var detectedVersion: ArgyllVersion?
    public var parserVersion: Int
    public var rawOutput: String

    public init(
        measurement: Measurement,
        detectedVersion: ArgyllVersion?,
        parserVersion: Int = 1,
        rawOutput: String
    ) {
        self.measurement = measurement
        self.detectedVersion = detectedVersion
        self.parserVersion = parserVersion
        self.rawOutput = rawOutput
    }
}

public enum ArgyllSpotMeasurementParser {
    public static func parse(
        _ rawOutput: String,
        version: ArgyllVersion? = nil,
        capturedAt: Date = Date()
    ) throws -> ArgyllSpotMeasurementParseResult {
        let detectedVersion = version ?? ArgyllVersionParser.parse(rawOutput)
        try ArgyllParserCompatibility.validate(
            detectedVersion,
            parser: "spot-measurement-v1",
            rawOutput: rawOutput
        )

        let xyzValues = firstTriplet(after: #"\bXYZ\s*[:=]"#, in: rawOutput)
        let yxyValues = firstTriplet(after: #"\bYxy\s*[:=]"#, in: rawOutput)

        let xyz: XYZColor
        let chromaticity: Chromaticity
        let luminance: Double
        if let values = xyzValues {
            xyz = XYZColor(x: values[0], y: values[1], z: values[2])
            luminance = values[1]
            if let yxyValues, validChromaticity(x: yxyValues[1], y: yxyValues[2]) {
                chromaticity = Chromaticity(x: yxyValues[1], y: yxyValues[2])
            } else {
                let total = values.reduce(0, +)
                guard total > 0 else {
                    throw unsupported(rawOutput, version: detectedVersion)
                }
                chromaticity = Chromaticity(x: values[0] / total, y: values[1] / total)
            }
        } else if let values = yxyValues, validChromaticity(x: values[1], y: values[2]) {
            luminance = values[0]
            let x = values[1]
            let y = values[2]
            xyz = XYZColor(
                x: x * luminance / y,
                y: luminance,
                z: (1 - x - y) * luminance / y
            )
            chromaticity = Chromaticity(x: x, y: y)
        } else {
            throw unsupported(rawOutput, version: detectedVersion)
        }

        guard [xyz.x, xyz.y, xyz.z, chromaticity.x, chromaticity.y, luminance].allSatisfy(\.isFinite), luminance >= 0 else {
            throw unsupported(rawOutput, version: detectedVersion)
        }

        let cct = firstNumber(
            matching: #"\bCCT\s*[:=]\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*K?"#,
            in: rawOutput
        )
        let warnings = rawOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let lower = line.lowercased()
            guard lower.contains("warning") || lower.contains("caution") || lower.contains("low light") else {
                return nil
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let measurement = Measurement(
            xyz: xyz,
            chromaticity: chromaticity,
            luminanceCDM2: luminance,
            correlatedColorTemperature: cct,
            rgbBalance: rgbBalance(for: xyz),
            capturedAt: capturedAt,
            warnings: warnings,
            rawSource: rawOutput
        )
        return ArgyllSpotMeasurementParseResult(
            measurement: measurement,
            detectedVersion: detectedVersion,
            rawOutput: rawOutput
        )
    }

    private static func unsupported(_ raw: String, version: ArgyllVersion?) -> ArgyllEngineError {
        .unsupportedOutput(
            parser: "spot-measurement-v1",
            version: version,
            excerpt: ArgyllParserCompatibility.excerpt(raw)
        )
    }

    private static func validChromaticity(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && x >= 0 && y > 0 && x <= 1 && y <= 1 && x + y <= 1
    }

    private static func rgbBalance(for xyz: XYZColor) -> [Double]? {
        let r = 3.2406 * xyz.x - 1.5372 * xyz.y - 0.4986 * xyz.z
        let g = -0.9689 * xyz.x + 1.8758 * xyz.y + 0.0415 * xyz.z
        let b = 0.0557 * xyz.x - 0.2040 * xyz.y + 1.0570 * xyz.z
        let values = [max(0, r), max(0, g), max(0, b)]
        let mean = values.reduce(0, +) / 3
        guard mean.isFinite, mean > 0 else { return nil }
        return values.map { $0 / mean * 100 }
    }
}

public struct ArgyllConsoleParseResult: Sendable {
    public var progress: [(completed: Int, total: Int?)]
    public var warnings: [String]
    public var messages: [String]
    public var rawOutput: String
    public var parserVersion: Int

    public init(
        progress: [(completed: Int, total: Int?)],
        warnings: [String],
        messages: [String],
        rawOutput: String,
        parserVersion: Int = 1
    ) {
        self.progress = progress
        self.warnings = warnings
        self.messages = messages
        self.rawOutput = rawOutput
        self.parserVersion = parserVersion
    }
}

enum ArgyllConsoleStreamEvent: Equatable, Sendable {
    case progress(completed: Int, total: Int?)
    case warning(String)
    case message(String)
    case technical(String)
}

/// Converts arbitrarily chunked process output into complete console lines.
/// Argyll uses a mix of LF, CRLF, and bare CR updates, and a `Data` chunk can
/// end in the middle of either a delimiter or a UTF-8 scalar. Keeping bytes
/// until a complete line is available avoids corrupting either case.
struct ArgyllConsoleStreamParser: Sendable {
    private var pendingLine = Data()
    private var suppressLeadingLineFeed = false
    private var isFinished = false

    mutating func consume(_ data: Data) -> [ArgyllConsoleStreamEvent] {
        guard !isFinished, !data.isEmpty else { return [] }
        var events: [ArgyllConsoleStreamEvent] = []

        for byte in data {
            if suppressLeadingLineFeed {
                suppressLeadingLineFeed = false
                if byte == 0x0A { continue }
            }

            switch byte {
            case 0x0D:
                events.append(contentsOf: emitPendingLine())
                suppressLeadingLineFeed = true
            case 0x0A:
                events.append(contentsOf: emitPendingLine())
            default:
                pendingLine.append(byte)
            }
        }
        return events
    }

    mutating func finish() -> [ArgyllConsoleStreamEvent] {
        guard !isFinished else { return [] }
        isFinished = true
        suppressLeadingLineFeed = false
        return emitPendingLine()
    }

    private mutating func emitPendingLine() -> [ArgyllConsoleStreamEvent] {
        defer { pendingLine.removeAll(keepingCapacity: true) }
        let line = String(decoding: pendingLine, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        return ArgyllConsoleParser.events(forLine: line)
    }
}

public enum ArgyllConsoleParser {
    public static func parse(
        tool: ArgyllTool,
        rawOutput: String,
        version: ArgyllVersion? = nil
    ) throws -> ArgyllConsoleParseResult {
        try ArgyllParserCompatibility.validate(
            version ?? ArgyllVersionParser.parse(rawOutput),
            parser: "\(tool.rawValue)-console-v1",
            rawOutput: rawOutput
        )
        var progress: [(Int, Int?)] = []
        var warnings: [String] = []
        var messages: [String] = []

        for rawLine in rawOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for event in events(forLine: line) {
                switch event {
                case .progress(let completed, let total):
                    progress.append((completed, total))
                case .warning(let warning):
                    warnings.append(warning)
                case .message(let message):
                    messages.append(message)
                case .technical:
                    break
                }
            }
        }
        return ArgyllConsoleParseResult(
            progress: progress,
            warnings: warnings,
            messages: messages,
            rawOutput: rawOutput
        )
    }

    fileprivate static func events(forLine line: String) -> [ArgyllConsoleStreamEvent] {
        let lower = line.lowercased()
        var events: [ArgyllConsoleStreamEvent] = []
        if lower.contains("warning") || lower.contains("caution") {
            events.append(.warning(line))
        }
        if let pair = patchProgress(line) {
            events.append(.progress(completed: pair.0, total: pair.1))
        } else if let percent = percentage(line) {
            events.append(.progress(completed: percent, total: 100))
        }
        if lower.contains("complete") || lower.contains("finished") || lower.contains("created") {
            events.append(.message(line))
        }
        if events.isEmpty {
            events.append(.technical(line))
        }
        return events
    }

    private static func patchProgress(_ line: String) -> (Int, Int?)? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:patch|point|sample|reading)\s*(\d+)\s*(?:of|/)\s*(\d+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = expression.firstMatch(in: line, range: range),
            let completedRange = Range(match.range(at: 1), in: line),
            let totalRange = Range(match.range(at: 2), in: line),
            let completed = Int(line[completedRange]),
            let total = Int(line[totalRange]), total > 0, completed >= 0, completed <= total
        else { return nil }
        return (completed, total)
    }

    private static func percentage(_ line: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,3})(?:\.\d+)?\s*%"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = expression.firstMatch(in: line, range: range),
            let valueRange = Range(match.range(at: 1), in: line),
            let value = Int(line[valueRange]), value <= 100
        else { return nil }
        return value
    }
}

private func numberedEntry(_ line: String) -> (id: String, name: String, trailing: String)? {
    let patterns = [
        #"^\s*(\d+)\s*=\s*['\"]([^'\"]+)['\"](.*)$"#,
        #"^\s*(\d+)\s*[:)]\s*(.+?)\s*$"#,
    ]
    for pattern in patterns {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = expression.firstMatch(in: line, range: range),
            let idRange = Range(match.range(at: 1), in: line),
            let nameRange = Range(match.range(at: 2), in: line)
        else { continue }
        let trailing = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        return (
            String(line[idRange]),
            String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
            trailing
        )
    }
    return nil
}

private func firstTriplet(after prefix: String, in value: String) -> [Double]? {
    let number = #"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"#
    let pattern = prefix + #"\s*"# + number + #"\s*[, ]\s*"# + number + #"\s*[, ]\s*"# + number
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range) else { return nil }
    return (1...3).compactMap { index -> Double? in
        guard let valueRange = Range(match.range(at: index), in: value) else { return nil }
        return Double(value[valueRange])
    }
}

private func firstNumber(matching pattern: String, in value: String) -> Double? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard
        let match = expression.firstMatch(in: value, range: range),
        let valueRange = Range(match.range(at: 1), in: value)
    else { return nil }
    return Double(value[valueRange])
}
