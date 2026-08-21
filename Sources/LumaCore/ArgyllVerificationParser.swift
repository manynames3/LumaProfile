import Foundation

public struct ArgyllCGATSDocument: Sendable {
    public var signature: String
    public var keywords: [String: String]
    public var fields: [String]
    public var rows: [[String]]
    public var rawText: String

    public init(
        signature: String,
        keywords: [String: String],
        fields: [String],
        rows: [[String]],
        rawText: String
    ) {
        self.signature = signature
        self.keywords = keywords
        self.fields = fields
        self.rows = rows
        self.rawText = rawText
    }

    public func column(_ name: String) -> Int? {
        fields.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func numericValue(row: Int, field: String) -> Double? {
        guard rows.indices.contains(row), let column = column(field), rows[row].indices.contains(column) else {
            return nil
        }
        return Double(rows[row][column])
    }
}

public enum ArgyllCGATSParser {
    public static func parse(_ data: Data) throws -> ArgyllCGATSDocument {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "cgats-v1",
                version: nil,
                excerpt: "Input is not UTF-8/ASCII text."
            )
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines)
        guard let signature = lines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { throw malformed(text, "Missing CGATS signature.") }

        var keywords: [String: String] = [:]
        var fields: [String] = []
        var rows: [[String]] = []
        var section: Section = .header

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            switch line.uppercased() {
            case "BEGIN_DATA_FORMAT": section = .format; continue
            case "END_DATA_FORMAT": section = .header; continue
            case "BEGIN_DATA": section = .data; continue
            case "END_DATA": section = .done; continue
            default: break
            }

            switch section {
            case .header:
                let tokens = tokenize(line)
                guard tokens.count >= 2 else { continue }
                keywords[tokens[0].uppercased()] = tokens.dropFirst().joined(separator: " ")
            case .format:
                fields.append(contentsOf: tokenize(line))
            case .data:
                rows.append(tokenize(line))
            case .done:
                continue
            }
        }

        guard !fields.isEmpty else { throw malformed(text, "Missing data format fields.") }
        guard !rows.isEmpty else { throw malformed(text, "Missing data rows.") }
        guard rows.allSatisfy({ $0.count == fields.count }) else {
            throw malformed(text, "A data row does not match NUMBER_OF_FIELDS.")
        }
        if let declaredFields = keywords["NUMBER_OF_FIELDS"].flatMap(Int.init), declaredFields != fields.count {
            throw malformed(text, "NUMBER_OF_FIELDS does not match the data format.")
        }
        if let declaredSets = keywords["NUMBER_OF_SETS"].flatMap(Int.init), declaredSets != rows.count {
            throw malformed(text, "NUMBER_OF_SETS does not match the data rows.")
        }

        return ArgyllCGATSDocument(
            signature: signature,
            keywords: keywords,
            fields: fields,
            rows: rows,
            rawText: text
        )
    }

    private enum Section { case header, format, data, done }

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func malformed(_ text: String, _ reason: String) -> ArgyllEngineError {
        .unsupportedOutput(
            parser: "cgats-v1",
            version: nil,
            excerpt: "\(reason) \(ArgyllParserCompatibility.excerpt(text))"
        )
    }
}

public struct ArgyllProfcheckPatch: Hashable, Sendable {
    public var patchNumber: Int
    public var deltaE2000: Double
    public var deviceValues: [Double]

    public init(patchNumber: Int, deltaE2000: Double, deviceValues: [Double]) {
        self.patchNumber = patchNumber
        self.deltaE2000 = deltaE2000
        self.deviceValues = deviceValues
    }
}

public struct ArgyllProfcheckParseResult: Sendable {
    public var patches: [ArgyllProfcheckPatch]
    public var averageDeltaE2000: Double
    public var percentile95DeltaE2000: Double
    public var maximumDeltaE2000: Double
    public var whitePatchDeltaE2000: Double?
    public var warnings: [String]
    public var rawOutput: String
    public var parserVersion: Int

    public init(
        patches: [ArgyllProfcheckPatch],
        averageDeltaE2000: Double,
        percentile95DeltaE2000: Double,
        maximumDeltaE2000: Double,
        whitePatchDeltaE2000: Double?,
        warnings: [String],
        rawOutput: String,
        parserVersion: Int = 1
    ) {
        self.patches = patches
        self.averageDeltaE2000 = averageDeltaE2000
        self.percentile95DeltaE2000 = percentile95DeltaE2000
        self.maximumDeltaE2000 = maximumDeltaE2000
        self.whitePatchDeltaE2000 = whitePatchDeltaE2000
        self.warnings = warnings
        self.rawOutput = rawOutput
        self.parserVersion = parserVersion
    }
}

public enum ArgyllProfcheckParser {
    public static func parse(_ rawOutput: String, version: ArgyllVersion? = nil) throws -> ArgyllProfcheckParseResult {
        try ArgyllParserCompatibility.validate(
            version ?? ArgyllVersionParser.parse(rawOutput),
            parser: "profcheck-v1",
            rawOutput: rawOutput
        )
        let patches = rawOutput.components(separatedBy: .newlines).compactMap(parsePatch)
        let warnings = rawOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let lower = line.lowercased()
            guard lower.contains("warning") || lower.contains("caution") else { return nil }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let average: Double
        let maximum: Double
        let percentile95: Double
        if !patches.isEmpty {
            let sorted = patches.map(\.deltaE2000).sorted()
            average = sorted.reduce(0, +) / Double(sorted.count)
            maximum = sorted.last ?? 0
            let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
            percentile95 = sorted[index]
        } else if
            let summaryAverage = summaryNumber(named: #"(?:avg|average)(?:\s+(?:err|error|delta\s*e))?"#, in: rawOutput),
            let summaryMaximum = summaryNumber(named: #"(?:max|maximum|peak)(?:\s+(?:err|error|delta\s*e))?"#, in: rawOutput)
        {
            average = summaryAverage
            maximum = summaryMaximum
            percentile95 = summaryNumber(named: #"(?:95(?:th)?(?:\s+percentile)?|p95)"#, in: rawOutput) ?? summaryMaximum
        } else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "profcheck-v1",
                version: version,
                excerpt: ArgyllParserCompatibility.excerpt(rawOutput)
            )
        }

        let whitePatch = patches
            .filter { $0.deviceValues.count >= 3 }
            .max { lhs, rhs in lhs.deviceValues.prefix(3).reduce(0, +) < rhs.deviceValues.prefix(3).reduce(0, +) }
        return ArgyllProfcheckParseResult(
            patches: patches,
            averageDeltaE2000: average,
            percentile95DeltaE2000: percentile95,
            maximumDeltaE2000: maximum,
            whitePatchDeltaE2000: whitePatch?.deltaE2000,
            warnings: warnings,
            rawOutput: rawOutput
        )
    }

    private static func parsePatch(_ line: String) -> ArgyllProfcheckPatch? {
        let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
        let patterns = [
            #"^\s*\[\s*("# + number + #")\s*\]\s*(?:Patch\s*)?(\d+)\s*:\s*(.*?)\s*->"#,
            #"^\s*("# + number + #")\s+(?:Patch\s*)?(\d+)\s*:\s*(.*?)\s*->"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard
                let match = expression.firstMatch(in: line, range: range),
                let deltaRange = Range(match.range(at: 1), in: line),
                let patchRange = Range(match.range(at: 2), in: line),
                let deviceRange = Range(match.range(at: 3), in: line),
                let delta = Double(line[deltaRange]),
                let patch = Int(line[patchRange])
            else { continue }
            let deviceValues = line[deviceRange]
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .compactMap { Double($0) }
            return ArgyllProfcheckPatch(patchNumber: patch, deltaE2000: delta, deviceValues: deviceValues)
        }
        return nil
    }

    private static func summaryNumber(named namePattern: String, in output: String) -> Double? {
        let number = #"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"#
        let pattern = namePattern + #"\s*[:=]\s*"# + number
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard
            let match = expression.firstMatch(in: output, range: range),
            let numberRange = Range(match.range(at: 1), in: output)
        else { return nil }
        return Double(output[numberRange])
    }
}

public enum ArgyllVerificationParser {
    public static func parse(
        profcheckOutput: String,
        measurementData: Data,
        target: CalibrationTarget? = nil,
        version: ArgyllVersion? = nil,
        measuredAt: Date = Date()
    ) throws -> VerificationReport {
        let profcheck = try ArgyllProfcheckParser.parse(profcheckOutput, version: version)
        let cgats = try ArgyllCGATSParser.parse(measurementData)
        let samples = try rgbXYZSamples(from: cgats)
        guard let white = samples.max(by: { $0.inputAverage < $1.inputAverage }) else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "verification-v1",
                version: version,
                excerpt: "No RGB/XYZ samples were present in the verification .ti3 file."
            )
        }
        let black = samples.min(by: { $0.inputAverage < $1.inputAverage })
        let sum = white.x + white.y + white.z
        guard sum > 0 else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "verification-v1",
                version: version,
                excerpt: "The measured white XYZ value is zero."
            )
        }

        let measuredWhite = Chromaticity(x: white.x / sum, y: white.y / sum)
        var warnings = profcheck.warnings
        let luminance = luminanceFromKeyword(cgats.keywords["LUMINANCE_XYZ_CDM2"]) ?? white.y
        if cgats.keywords["LUMINANCE_XYZ_CDM2"] == nil {
            warnings.append("The .ti3 file did not declare LUMINANCE_XYZ_CDM2; reported luminance may be normalized rather than cd/m².")
        }
        let blackLevel: Double? = black.flatMap { sample in
            guard white.y > 0 else { return nil }
            return max(0, sample.y / white.y * luminance)
        }
        let contrast = blackLevel.flatMap { $0 > 0 ? luminance / $0 : nil }
        let gamma = gammaFit(samples: samples, blackY: black?.y ?? 0, whiteY: white.y)
        let targetWhite = target.flatMap(targetWhiteChromaticity)
        let whitePointError: Double
        if let targetWhite,
           let targetError = ColorScience.whitePointDeltaE2000(measured: measuredWhite, target: targetWhite) {
            whitePointError = targetError
        } else {
            whitePointError = profcheck.whitePatchDeltaE2000 ?? 0
            if target != nil {
                warnings.append("The selected target has no fixed computable white chromaticity; the white-patch profile-fit error is shown instead.")
            } else if profcheck.whitePatchDeltaE2000 == nil {
                warnings.append("profcheck did not expose a separately identifiable white-patch error.")
            }
        }
        let toneResponseError = target.flatMap {
            toneResponseRMSError(
                samples: samples,
                blackY: black?.y ?? 0,
                whiteY: white.y,
                transferFunction: $0.transferFunction
            )
        }

        let metrics = VerificationMetrics(
            averageDeltaE2000: profcheck.averageDeltaE2000,
            percentile95DeltaE2000: profcheck.percentile95DeltaE2000,
            maximumDeltaE2000: profcheck.maximumDeltaE2000,
            whitePointDeltaE2000: whitePointError,
            measuredWhite: measuredWhite,
            luminanceCDM2: luminance,
            blackLevelCDM2: blackLevel,
            contrastRatio: contrast,
            measuredGamma: gamma?.gamma,
            gammaRMSError: gamma?.rms,
            measuredCorrelatedColorTemperature: ColorScience.correlatedColorTemperature(from: measuredWhite),
            targetWhite: targetWhite,
            targetLuminanceCDM2: target?.luminanceCDM2,
            targetTransferFunction: target?.transferFunction,
            toneResponseRMSError: toneResponseError,
            warnings: warnings
        )
        let combinedRaw = profcheckOutput + "\n\n--- verification.ti3 ---\n" + cgats.rawText
        return VerificationReport(metrics: metrics, rawOutput: combinedRaw, measuredAt: measuredAt)
    }

    private struct RGBXYZSample {
        var r: Double
        var g: Double
        var b: Double
        var x: Double
        var y: Double
        var z: Double
        var inputAverage: Double { (r + g + b) / 3 }
    }

    private static func rgbXYZSamples(from document: ArgyllCGATSDocument) throws -> [RGBXYZSample] {
        let required = ["RGB_R", "RGB_G", "RGB_B", "XYZ_X", "XYZ_Y", "XYZ_Z"]
        guard required.allSatisfy({ document.column($0) != nil }) else {
            throw ArgyllEngineError.unsupportedOutput(
                parser: "verification-v1",
                version: nil,
                excerpt: "Verification .ti3 is missing one of: \(required.joined(separator: ", "))."
            )
        }
        return document.rows.indices.compactMap { row in
            guard
                let r = document.numericValue(row: row, field: "RGB_R"),
                let g = document.numericValue(row: row, field: "RGB_G"),
                let b = document.numericValue(row: row, field: "RGB_B"),
                let x = document.numericValue(row: row, field: "XYZ_X"),
                let y = document.numericValue(row: row, field: "XYZ_Y"),
                let z = document.numericValue(row: row, field: "XYZ_Z"),
                [r, g, b, x, y, z].allSatisfy(\.isFinite)
            else { return nil }
            return RGBXYZSample(r: r, g: g, b: b, x: x, y: y, z: z)
        }
    }

    private static func luminanceFromKeyword(_ value: String?) -> Double? {
        guard let value else { return nil }
        let numbers = value.split(whereSeparator: \Character.isWhitespace).compactMap { Double($0) }
        guard numbers.count >= 2, numbers[1].isFinite, numbers[1] >= 0 else { return nil }
        return numbers[1]
    }

    private static func gammaFit(
        samples: [RGBXYZSample],
        blackY: Double,
        whiteY: Double
    ) -> (gamma: Double, rms: Double)? {
        let grayscale = normalizedGrayscaleSamples(samples: samples, blackY: blackY, whiteY: whiteY)
        guard grayscale.count >= 3 else { return nil }
        let numerator = grayscale.reduce(0.0) { $0 + log($1.input) * log($1.output) }
        let denominator = grayscale.reduce(0.0) { $0 + pow(log($1.input), 2) }
        guard denominator > 0 else { return nil }
        let gamma = numerator / denominator
        let rms = sqrt(grayscale.reduce(0.0) { partial, point in
            let residual = pow(point.input, gamma) - point.output
            return partial + residual * residual
        } / Double(grayscale.count))
        return gamma.isFinite && rms.isFinite ? (gamma, rms) : nil
    }

    private static func toneResponseRMSError(
        samples: [RGBXYZSample],
        blackY: Double,
        whiteY: Double,
        transferFunction: TransferFunction
    ) -> Double? {
        let grayscale = normalizedGrayscaleSamples(samples: samples, blackY: blackY, whiteY: whiteY)
        guard grayscale.count >= 3 else { return nil }
        let meanSquaredError = grayscale.reduce(0.0) { partial, point in
            let expected: Double = switch transferFunction {
            case .gamma(let value): pow(point.input, value)
            case .sRGB:
                point.input <= 0.04045
                    ? point.input / 12.92
                    : pow((point.input + 0.055) / 1.055, 2.4)
            case .bt1886:
                // Matches the product's explicit BT.1886-style -G2.4 -f0 target.
                pow(point.input, 2.4)
            }
            let residual = expected - point.output
            return partial + residual * residual
        } / Double(grayscale.count)
        let rms = sqrt(meanSquaredError)
        return rms.isFinite ? rms : nil
    }

    private static func normalizedGrayscaleSamples(
        samples: [RGBXYZSample],
        blackY: Double,
        whiteY: Double
    ) -> [(input: Double, output: Double)] {
        guard whiteY > blackY else { return [] }
        let inputMaximum = samples.map(\.inputAverage).max() ?? 100
        guard inputMaximum > 0 else { return [] }
        return samples.filter {
            abs($0.r - $0.g) < 0.001 * inputMaximum
                && abs($0.g - $0.b) < 0.001 * inputMaximum
        }.compactMap { sample in
            let input = sample.inputAverage / inputMaximum
            let output = (sample.y - blackY) / (whiteY - blackY)
            guard input > 0.02, input < 0.98, output > 0, output < 1 else { return nil }
            return (input, output)
        }
    }

    private static func targetWhiteChromaticity(_ target: CalibrationTarget) -> Chromaticity? {
        switch target.whitePoint {
        case .native: nil
        case .d65: .d65
        case .temperature(let kelvin): ColorScience.chromaticity(forColorTemperature: kelvin)
        case .chromaticity(let chromaticity): chromaticity
        }
    }
}
