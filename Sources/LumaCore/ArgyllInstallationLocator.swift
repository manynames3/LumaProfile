import Foundation

public struct ArgyllInstallationLocator: ArgyllInstallationLocating, Sendable {
    public static var defaultBundledDirectory: URL? {
        guard let resourcesDirectory = Bundle.main.resourceURL else { return nil }
        let candidate = resourcesDirectory
            .appendingPathComponent("ThirdParty", isDirectory: true)
            .appendingPathComponent("ArgyllCMS", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return candidate
    }

    public static let defaultCommonDirectories: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        URL(fileURLWithPath: "/opt/local/bin", isDirectory: true),
        URL(fileURLWithPath: "/Applications/ArgyllCMS/bin", isDirectory: true),
        URL(fileURLWithPath: "/Applications/Argyll/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Argyll/bin", isDirectory: true),
    ]

    public var explicitDirectory: URL?
    public var bundledDirectory: URL?
    public var environment: [String: String]
    public var commonDirectories: [URL]

    public init(
        explicitDirectory: URL? = nil,
        bundledDirectory: URL? = ArgyllInstallationLocator.defaultBundledDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commonDirectories: [URL] = ArgyllInstallationLocator.defaultCommonDirectories
    ) {
        self.explicitDirectory = explicitDirectory
        self.bundledDirectory = bundledDirectory
        self.environment = environment
        self.commonDirectories = commonDirectories
    }

    public func locate() -> ArgyllInstallationDiscovery {
        let directories = candidateDirectories()
        var reports: [ArgyllCandidateReport] = []

        for directory in directories {
            let evaluation = evaluate(directory)
            reports.append(evaluation.report)
            if let installation = evaluation.installation {
                return ArgyllInstallationDiscovery(
                    installation: installation,
                    candidates: reports,
                    diagnostic: "Found a coherent ArgyllCMS tool set in \(installation.directory.path)."
                )
            }
        }

        let searched = directories.map(\.path).joined(separator: ", ")
        let detail = reports
            .filter { $0.toolStatus.values.contains(true) }
            .map(\.diagnostic)
            .joined(separator: " ")
        let suffix = detail.isEmpty ? "" : " \(detail)"
        return ArgyllInstallationDiscovery(
            installation: nil,
            candidates: reports,
            diagnostic: "No directory contained every required ArgyllCMS tool. Searched: \(searched).\(suffix)"
        )
    }

    private func candidateDirectories() -> [URL] {
        var candidates: [URL] = []
        if let explicitDirectory {
            candidates.append(explicitDirectory)
        }
        if let bundledDirectory {
            candidates.append(bundledDirectory)
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                let value = String(component)
                guard value.hasPrefix("/") else { continue }
                candidates.append(URL(fileURLWithPath: value, isDirectory: true))
            }
        }
        candidates.append(contentsOf: commonDirectories)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard candidate.isFileURL else { return nil }
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private func evaluate(_ requestedDirectory: URL) -> (
        installation: ArgyllInstallation?,
        report: ArgyllCandidateReport
    ) {
        let fileManager = FileManager.default
        var status: [ArgyllTool: Bool] = [:]
        var resolvedExecutables: [ArgyllTool: URL] = [:]

        for tool in ArgyllTool.allCases {
            let candidate = requestedDirectory.appendingPathComponent(tool.rawValue, isDirectory: false)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            let usable = exists && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: candidate.path)
            status[tool] = usable
            if usable {
                resolvedExecutables[tool] = candidate.resolvingSymlinksInPath().standardizedFileURL
            }
        }

        let requiredURLs = ArgyllTool.requiredForP0.compactMap { resolvedExecutables[$0] }
        let resolvedParents = Set(requiredURLs.map { $0.deletingLastPathComponent().path })
        let allRequiredPresent = ArgyllTool.requiredForP0.allSatisfy { status[$0] == true }
        let coherent = allRequiredPresent && resolvedParents.count == 1

        guard coherent, let resolvedPath = resolvedParents.first else {
            let missing = ArgyllTool.requiredForP0.filter { status[$0] != true }.map(\.rawValue)
            let reason: String
            if !missing.isEmpty {
                reason = "\(requestedDirectory.path) is incomplete; missing: \(missing.joined(separator: ", "))."
            } else {
                reason = "\(requestedDirectory.path) resolves required tools into multiple binary directories; refusing to mix installations."
            }
            return (
                nil,
                ArgyllCandidateReport(
                    requestedDirectory: requestedDirectory,
                    resolvedDirectory: resolvedParents.count == 1
                        ? URL(fileURLWithPath: resolvedParents.first!, isDirectory: true)
                        : nil,
                    toolStatus: status,
                    diagnostic: reason
                )
            )
        }

        let resolvedDirectory = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        let coherentExecutables = resolvedExecutables.filter { $0.value.deletingLastPathComponent() == resolvedDirectory }
        let installation = ArgyllInstallation(directory: resolvedDirectory, executables: coherentExecutables)
        return (
            installation,
            ArgyllCandidateReport(
                requestedDirectory: requestedDirectory,
                resolvedDirectory: resolvedDirectory,
                toolStatus: status,
                diagnostic: "Coherent ArgyllCMS installation found at \(resolvedDirectory.path)."
            )
        )
    }
}
