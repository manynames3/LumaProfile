import Foundation

public enum ArgyllTool: String, CaseIterable, Codable, Hashable, Sendable {
    case spotread
    case dispcal
    case targen
    case dispread
    case colprof
    case profcheck
    case dispwin
    case xicclu

    public static let requiredForP0: [ArgyllTool] = [
        .spotread, .dispcal, .targen, .dispread, .colprof, .profcheck, .dispwin,
    ]

    public var isRequiredForP0: Bool { Self.requiredForP0.contains(self) }
}

public struct ArgyllVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var suffix: String?

    public init(major: Int, minor: Int, patch: Int = 0, suffix: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    public init?(_ value: String) {
        let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?([A-Za-z0-9._-]*)"#
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = expression?.firstMatch(in: value, range: range),
            let majorRange = Range(match.range(at: 1), in: value),
            let minorRange = Range(match.range(at: 2), in: value),
            let major = Int(value[majorRange]),
            let minor = Int(value[minorRange])
        else { return nil }

        let patch: Int
        if let patchRange = Range(match.range(at: 3), in: value) {
            patch = Int(value[patchRange]) ?? 0
        } else {
            patch = 0
        }
        let suffixRange = Range(match.range(at: 4), in: value)
        let parsedSuffix = suffixRange.map { String(value[$0]) }.flatMap { $0.isEmpty ? nil : $0 }
        self.init(major: major, minor: minor, patch: patch, suffix: parsedSuffix)
    }

    public static func < (lhs: ArgyllVersion, rhs: ArgyllVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return (lhs.suffix ?? "") < (rhs.suffix ?? "")
    }

    public var description: String {
        "\(major).\(minor).\(patch)\(suffix ?? "")"
    }
}

public struct ArgyllInstallation: Sendable {
    public var directory: URL
    public var executables: [ArgyllTool: URL]

    public init(directory: URL, executables: [ArgyllTool: URL]) {
        self.directory = directory
        self.executables = executables
    }

    public func executable(for tool: ArgyllTool) throws -> URL {
        guard let url = executables[tool] else {
            throw ArgyllEngineError.missingTool(tool)
        }
        return url
    }
}

public struct ArgyllCandidateReport: Sendable {
    public var requestedDirectory: URL
    public var resolvedDirectory: URL?
    public var toolStatus: [ArgyllTool: Bool]
    public var diagnostic: String

    public init(
        requestedDirectory: URL,
        resolvedDirectory: URL?,
        toolStatus: [ArgyllTool: Bool],
        diagnostic: String
    ) {
        self.requestedDirectory = requestedDirectory
        self.resolvedDirectory = resolvedDirectory
        self.toolStatus = toolStatus
        self.diagnostic = diagnostic
    }
}

public struct ArgyllInstallationDiscovery: Sendable {
    public var installation: ArgyllInstallation?
    public var candidates: [ArgyllCandidateReport]
    public var diagnostic: String

    public init(
        installation: ArgyllInstallation?,
        candidates: [ArgyllCandidateReport],
        diagnostic: String
    ) {
        self.installation = installation
        self.candidates = candidates
        self.diagnostic = diagnostic
    }
}

public protocol ArgyllInstallationLocating: Sendable {
    func locate() -> ArgyllInstallationDiscovery
}

public enum ArgyllEngineError: Error, LocalizedError, Sendable {
    case engineUnavailable(String)
    case missingTool(ArgyllTool)
    case invalidRequest(String)
    case processFailed(tool: ArgyllTool, exitCode: Int32, output: String)
    case unsupportedOutput(parser: String, version: ArgyllVersion?, excerpt: String)
    case missingArtifact(URL)
    case malformedArtifact(URL, reason: String)
    case unsafePrompt(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let diagnostic):
            return "ArgyllCMS is unavailable. \(diagnostic)"
        case .missingTool(let tool):
            return "The ArgyllCMS installation is missing \(tool.rawValue)."
        case .invalidRequest(let message):
            return message
        case .processFailed(let tool, let exitCode, let output):
            return "\(tool.rawValue) exited with status \(exitCode). \(output)"
        case .unsupportedOutput(let parser, let version, let excerpt):
            let versionText = version.map(String.init(describing:)) ?? "unknown"
            return "\(parser) does not support this ArgyllCMS \(versionText) output: \(excerpt)"
        case .missingArtifact(let url):
            return "ArgyllCMS did not create the expected artifact at \(url.path)."
        case .malformedArtifact(let url, let reason):
            return "The artifact at \(url.path) is invalid: \(reason)"
        case .unsafePrompt(let prompt):
            return "Automation stopped at an unknown or unsafe prompt: \(prompt)"
        }
    }
}

public struct ArgyllInvocation: Hashable, Sendable {
    public var tool: ArgyllTool
    public var executableURL: URL
    public var arguments: [String]

    public init(tool: ArgyllTool, executableURL: URL, arguments: [String]) {
        self.tool = tool
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// ArgyllCMS options that write a display's colour curve or its profile
    /// file beyond the life of the process. On macOS, `dispwin` makes a
    /// calibration "persistent" by renaming the display's current profile to
    /// `.orig`, writing a "Dispwin Temp" copy with a new vcgt in its place and
    /// renaming it back afterwards (ArgyllCMS 3.5.0 spectro/dispwin.c). Any
    /// failure or interruption in between leaves the user's profile replaced,
    /// which blanks the screen whenever macOS reloads it, including on wake.
    /// LumaProfile never needs this: it only asks `dispwin` for its usage text,
    /// and `dispread` applies calibration to patch values (`-K`), not the
    /// VideoLUT (`-k`).
    public var displayStateViolation: String? {
        switch tool {
        case .dispwin:
            return arguments == ["-?"]
                ? nil
                : "dispwin may only be run as 'dispwin -?'; any other use can rewrite a display profile."
        case .dispread:
            return arguments.contains("-k")
                ? "dispread -k loads a calibration into a display's VideoLUT."
                : nil
        default:
            return nil
        }
    }

    /// Builds the process request, refusing any invocation that could change
    /// a display's curve or profile outside the measuring process.
    public func validatedProcessRequest(
        workingDirectoryURL: URL,
        timeout: Duration? = nil,
        standardInput: Data? = nil
    ) throws -> ProcessRequest {
        if let displayStateViolation {
            throw ArgyllEngineError.invalidRequest("Refused to run ArgyllCMS: \(displayStateViolation)")
        }
        return processRequest(
            workingDirectoryURL: workingDirectoryURL,
            timeout: timeout,
            standardInput: standardInput
        )
    }

    public func processRequest(
        workingDirectoryURL: URL,
        timeout: Duration? = nil,
        standardInput: Data? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProcessRequest {
        let executableDirectory = executableURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        let path = if let inheritedPath = inheritedEnvironment["PATH"], !inheritedPath.isEmpty {
            "\(executableDirectory):\(inheritedPath)"
        } else {
            executableDirectory
        }

        return ProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: workingDirectoryURL,
            environment: [
                "ARGYLL_NOT_INTERACTIVE": "1",
                "LC_ALL": "C",
                "LANG": "C",
                "PATH": path,
            ],
            timeout: timeout,
            standardInput: standardInput
        )
    }
}
