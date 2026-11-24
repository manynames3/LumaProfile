import Foundation

public enum ArgyllCommandBuilder {
    public static func probe(installation: ArgyllInstallation) throws -> ArgyllInvocation {
        ArgyllInvocation(
            tool: .spotread,
            executableURL: try installation.executable(for: .spotread),
            arguments: ["-?"]
        )
    }

    public static func instrumentDiscovery(installation: ArgyllInstallation) throws -> ArgyllInvocation {
        try probe(installation: installation)
    }

    public static func spotMeasurement(
        installation: ArgyllInstallation,
        request: SpotMeasurementRequest,
        continuous: Bool = false
    ) throws -> ArgyllInvocation {
        // `-O` exits after one reading. Without it spotread keeps the meter
        // open and prompts again after every reading.
        var arguments = ["-e", "-x", "-T"] + (continuous ? [] : ["-O"])
        arguments += try instrumentArguments(request.instrument)
        arguments += try correctionArguments(request.correction)
        arguments += spotreadMeasurementModeArguments(request.mode)
        return ArgyllInvocation(
            tool: .spotread,
            executableURL: try installation.executable(for: .spotread),
            arguments: arguments
        )
    }

    public static func dispcal(
        installation: ArgyllInstallation,
        request: CalibrationRequest,
        outputBaseURL: URL
    ) throws -> ArgyllInvocation {
        let displayIndex = try requiredDisplayIndex(request.display)
        var arguments = [
            "-v2",
            "-d", String(displayIndex),
            "-m",
        ]
        arguments += try instrumentArguments(request.instrument)
        arguments += ["-q\(qualityCode(request.target.quality))"]
        arguments += try targetArguments(request.target)
        arguments += try correctionArguments(request.correction)
        arguments += displayMeasurementModeArguments(request.mode)
        arguments += ["-P", try patchWindowArgument(request.target.patchGeometry)]
        arguments.append(try basePath(outputBaseURL, removingExtension: "cal"))

        return ArgyllInvocation(
            tool: .dispcal,
            executableURL: try installation.executable(for: .dispcal),
            arguments: arguments
        )
    }

    public static func targen(
        installation: ArgyllInstallation,
        preset: CharacterizationPreset,
        outputBaseURL: URL
    ) throws -> ArgyllInvocation {
        let settings: (single: Int, gray: Int, optimized: Bool)
        switch preset {
        case .fast: settings = (5, 17, false)
        case .standard: settings = (9, 21, false)
        case .high: settings = (13, 25, true)
        case .reference: settings = (17, 33, true)
        }

        var arguments = [
            "-v", "-d3", "-e4", "-B4",
            "-s\(settings.single)", "-g\(settings.gray)", "-f\(preset.requestedPatchCount)",
        ]
        if settings.optimized { arguments.append("-G") }
        arguments.append(try basePath(outputBaseURL, removingExtension: "ti1"))
        return ArgyllInvocation(
            tool: .targen,
            executableURL: try installation.executable(for: .targen),
            arguments: arguments
        )
    }

    public static func verificationTargen(
        installation: ArgyllInstallation,
        outputBaseURL: URL
    ) throws -> ArgyllInvocation {
        ArgyllInvocation(
            tool: .targen,
            executableURL: try installation.executable(for: .targen),
            arguments: [
                "-v", "-d3", "-e3", "-B3", "-s5", "-g17", "-f96", "-q",
                try basePath(outputBaseURL, removingExtension: "ti1"),
            ]
        )
    }

    public static func dispread(
        installation: ArgyllInstallation,
        request: CharacterizationRequest,
        inputOutputBaseURL: URL
    ) throws -> ArgyllInvocation {
        var arguments = try displayReadArguments(
            display: request.display,
            instrument: request.instrument,
            correction: request.correction,
            mode: request.mode,
            geometry: request.patchGeometry
        )
        // `-K` applies the calibration to the patch values. `-k` would load it
        // into the display's VideoLUT, and on a Mac with two displays
        // ArgyllCMS 3.5.0 then zeroes the main display's curve (a black
        // screen) while measuring the other one. Never let ArgyllCMS write a
        // VideoLUT here.
        arguments += ["-K", try absoluteFilePath(request.calibrationURL, expectedExtension: "cal")]
        arguments.append(try basePath(inputOutputBaseURL, removingExtension: "ti1"))
        return ArgyllInvocation(
            tool: .dispread,
            executableURL: try installation.executable(for: .dispread),
            arguments: arguments
        )
    }

    public static func verificationDispread(
        installation: ArgyllInstallation,
        request: VerificationRequest,
        inputOutputBaseURL: URL
    ) throws -> ArgyllInvocation {
        var arguments = try displayReadArguments(
            display: request.display,
            instrument: request.instrument,
            correction: request.correction,
            mode: request.mode,
            geometry: request.target.patchGeometry
        )
        arguments.append(try basePath(inputOutputBaseURL, removingExtension: "ti1"))
        return ArgyllInvocation(
            tool: .dispread,
            executableURL: try installation.executable(for: .dispread),
            arguments: arguments
        )
    }

    public static func colprof(
        installation: ArgyllInstallation,
        request: ProfileBuildRequest
    ) throws -> ArgyllInvocation {
        let algorithm: String
        switch request.model {
        case .matrix: algorithm = "-am"
        case .shaperMatrix: algorithm = "-as"
        case .lut: algorithm = "-aX"
        }

        var arguments = ["-v", "-qh", algorithm]
        if let manufacturer = request.metadata["manufacturer"] {
            arguments += ["-A", try safeMetadata(manufacturer, field: "manufacturer")]
        }
        arguments += ["-M", try safeMetadata(request.displayName, field: "display name")]
        arguments += ["-D", try safeMetadata(request.description, field: "description")]
        if let copyright = request.metadata["copyright"] {
            arguments += ["-C", try safeMetadata(copyright, field: "copyright")]
        }
        arguments += ["-Y", "c:\(try absoluteFilePath(request.calibrationURL, expectedExtension: "cal"))"]
        arguments += ["-O", try absoluteOutputPath(request.outputURL, allowedExtensions: ["icc", "icm"])]
        arguments.append(try basePath(request.measurementURL, removingExtension: "ti3"))

        return ArgyllInvocation(
            tool: .colprof,
            executableURL: try installation.executable(for: .colprof),
            arguments: arguments
        )
    }

    public static func profcheck(
        installation: ArgyllInstallation,
        measurementURL: URL,
        profileURL: URL
    ) throws -> ArgyllInvocation {
        ArgyllInvocation(
            tool: .profcheck,
            executableURL: try installation.executable(for: .profcheck),
            arguments: [
                "-k", "-v2",
                try absoluteFilePath(measurementURL, expectedExtension: "ti3"),
                try absoluteFilePath(profileURL, allowedExtensions: ["icc", "icm"]),
            ]
        )
    }

    /// Reloads the calibration from the profile currently associated with only
    /// the explicitly selected display. This does not install or associate a
    /// profile.
    public static func restoreActiveProfileCalibration(
        installation: ArgyllInstallation,
        display: PhysicalDisplay
    ) throws -> ArgyllInvocation {
        let displayIndex = try requiredDisplayIndex(display)
        return ArgyllInvocation(
            tool: .dispwin,
            executableURL: try installation.executable(for: .dispwin),
            arguments: ["-v", "-d", String(displayIndex), "-L"]
        )
    }

    public static func requiredDisplayIndex(_ display: PhysicalDisplay) throws -> Int {
        guard let index = display.argyllDisplayIndex, index > 0 else {
            throw ArgyllEngineError.invalidRequest(
                "The display has no confirmed ArgyllCMS display index. Identify and map the display before measuring it."
            )
        }
        return index
    }

    private static func displayReadArguments(
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        correction: DisplayCorrection?,
        mode: MeasurementMode,
        geometry: PatchGeometry?
    ) throws -> [String] {
        let displayIndex = try requiredDisplayIndex(display)
        var arguments = ["-v", "-d", String(displayIndex)]
        arguments += try instrumentArguments(instrument)
        arguments += try correctionArguments(correction)
        arguments += displayMeasurementModeArguments(mode)
        if let geometry {
            arguments += ["-P", try patchWindowArgument(geometry)]
        }
        return arguments
    }

    private static func instrumentArguments(_ instrument: InstrumentDescriptor) throws -> [String] {
        guard
            !instrument.id.isEmpty,
            instrument.id.allSatisfy(\.isNumber),
            let index = Int(instrument.id),
            index > 0
        else {
            throw ArgyllEngineError.invalidRequest("The selected instrument has an invalid ArgyllCMS list index.")
        }
        return ["-c", String(index)]
    }

    private static func correctionArguments(_ correction: DisplayCorrection?) throws -> [String] {
        guard let correction else { return [] }
        let path = try absoluteFilePath(
            correction.importedURL,
            expectedExtension: correction.kind.rawValue
        )
        return ["-X", path]
    }

    private static func spotreadMeasurementModeArguments(_ mode: MeasurementMode) -> [String] {
        switch mode {
        case .auto: return []
        case .refresh: return ["-Y", "r"]
        case .nonRefresh: return ["-Y", "n"]
        }
    }

    private static func displayMeasurementModeArguments(_ mode: MeasurementMode) -> [String] {
        switch mode {
        case .auto: return []
        case .refresh: return ["-y", "r"]
        case .nonRefresh: return ["-y", "n"]
        }
    }

    private static func targetArguments(_ target: CalibrationTarget) throws -> [String] {
        var arguments: [String] = []
        switch target.whitePoint {
        case .native:
            break
        case .d65:
            arguments += ["-t", "6500"]
        case .temperature(let kelvin):
            guard kelvin.isFinite, (1_000...25_000).contains(kelvin) else {
                throw ArgyllEngineError.invalidRequest("White-point temperature must be between 1000 K and 25000 K.")
            }
            arguments += ["-t", number(kelvin)]
        case .chromaticity(let chromaticity):
            guard
                chromaticity.x.isFinite, chromaticity.y.isFinite,
                chromaticity.x > 0, chromaticity.y > 0,
                chromaticity.x < 1, chromaticity.y < 1,
                chromaticity.x + chromaticity.y < 1
            else {
                throw ArgyllEngineError.invalidRequest("White-point chromaticity must be valid CIE x,y coordinates.")
            }
            arguments += ["-w", "\(number(chromaticity.x)),\(number(chromaticity.y))"]
        }

        if let luminance = target.luminanceCDM2 {
            guard luminance.isFinite, luminance > 0, luminance <= 10_000 else {
                throw ArgyllEngineError.invalidRequest("Target luminance must be greater than zero and at most 10000 cd/m².")
            }
            arguments += ["-b", number(luminance)]
        }

        switch target.transferFunction {
        case .gamma(let gamma):
            guard gamma.isFinite, (1.0...5.0).contains(gamma) else {
                throw ArgyllEngineError.invalidRequest("Gamma must be between 1.0 and 5.0.")
            }
            arguments.append("-g\(number(gamma))")
        case .sRGB:
            arguments.append("-gs")
        case .bt1886:
            arguments += ["-G2.4", "-f0"]
        }

        if target.blackPointMode == .optimize {
            arguments.append("-k0")
        }
        return arguments
    }

    private static func patchWindowArgument(_ geometry: PatchGeometry) throws -> String {
        guard
            geometry.widthFraction.isFinite, geometry.heightFraction.isFinite,
            geometry.horizontalPosition.isFinite, geometry.verticalPosition.isFinite,
            (0.01...1.0).contains(geometry.widthFraction),
            (0.01...1.0).contains(geometry.heightFraction),
            (0.0...1.0).contains(geometry.horizontalPosition),
            (0.0...1.0).contains(geometry.verticalPosition)
        else {
            throw ArgyllEngineError.invalidRequest("Patch size and position values are outside their supported ranges.")
        }

        // Argyll's -P dimensions are scale factors. Its documented fallback window is 10% of
        // display width, so product-level fractions are expressed relative to that baseline.
        let horizontalScale = geometry.widthFraction / 0.1
        let verticalScale = geometry.heightFraction / 0.1
        return [
            number(geometry.horizontalPosition),
            number(geometry.verticalPosition),
            number(horizontalScale),
            number(verticalScale),
        ].joined(separator: ",")
    }

    private static func qualityCode(_ quality: CalibrationQuality) -> String {
        switch quality {
        case .quick: return "l"
        case .medium: return "m"
        case .high: return "h"
        }
    }

    private static func safeMetadata(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 255,
            !trimmed.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) })
        else {
            throw ArgyllEngineError.invalidRequest("The profile \(field) is empty, too long, or contains control characters.")
        }
        return trimmed
    }

    private static func basePath(_ url: URL, removingExtension expectedExtension: String) throws -> String {
        let path = try absoluteFilePath(url, allowedExtensions: [expectedExtension, ""])
        if url.pathExtension.caseInsensitiveCompare(expectedExtension) == .orderedSame {
            return String(path.dropLast(expectedExtension.count + 1))
        }
        return path
    }

    private static func absoluteOutputPath(_ url: URL, allowedExtensions: Set<String>) throws -> String {
        try absoluteFilePath(url, allowedExtensions: allowedExtensions)
    }

    private static func absoluteFilePath(_ url: URL, expectedExtension: String) throws -> String {
        try absoluteFilePath(url, allowedExtensions: [expectedExtension])
    }

    private static func absoluteFilePath(_ url: URL, allowedExtensions: Set<String>) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw ArgyllEngineError.invalidRequest("ArgyllCMS input and output paths must be absolute file URLs without traversal components.")
        }
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw ArgyllEngineError.invalidRequest(
                "Unexpected file extension '.\(ext)' for \(url.lastPathComponent)."
            )
        }
        guard !url.path.utf8.contains(0) else {
            throw ArgyllEngineError.invalidRequest("A file path contains a null byte.")
        }
        return url.standardizedFileURL.path
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
