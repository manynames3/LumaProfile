import Foundation

public enum SessionStoreError: LocalizedError, Sendable {
    case sessionNotFound(UUID)
    case invalidSessionDirectory

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): "Calibration session \(id) was not found."
        case .invalidSessionDirectory: "The calibration session folder is unavailable."
        }
    }
}

public struct SessionLoadIssue: Hashable, Sendable, Identifiable {
    public var id: String { directoryName }
    public var directoryName: String
    public var message: String

    public init(directoryName: String, message: String) {
        self.directoryName = directoryName
        self.message = message
    }
}

public struct SessionListing: Sendable {
    public var sessions: [CalibrationSession]
    public var issues: [SessionLoadIssue]

    public init(sessions: [CalibrationSession], issues: [SessionLoadIssue]) {
        self.sessions = sessions
        self.issues = issues
    }
}

/// JSON-backed, atomic persistence for resumable calibration sessions.
public actor FileSessionStore: SessionStore {
    public let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaProfile/Sessions", directoryHint: .isDirectory)
    }

    public func create(_ session: CalibrationSession) async throws -> URL {
        let directory = directory(for: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // The workflow creates a session with its canonical creation/update
        // timestamps before asking the store for a directory. Preserve those
        // values so the in-memory and first durable records agree.
        try write(session, to: directory.appending(path: "session.json"), updatingTimestamp: false)
        return directory
    }

    public func save(_ session: CalibrationSession) async throws {
        let directory = directory(for: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(session, to: directory.appending(path: "session.json"), updatingTimestamp: true)
    }

    public func load(id: UUID) async throws -> CalibrationSession {
        let url = directory(for: id).appending(path: "session.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        return try decoder().decode(CalibrationSession.self, from: Data(contentsOf: url))
    }

    public func list() async throws -> [CalibrationSession] {
        (try await listing()).sessions
    }

    public func listing() async throws -> SessionListing {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return SessionListing(sessions: [], issues: [])
        }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var sessions: [CalibrationSession] = []
        var issues: [SessionLoadIssue] = []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let sessionURL = directory.appending(path: "session.json")
            do {
                let data = try Data(contentsOf: sessionURL)
                sessions.append(try decoder().decode(CalibrationSession.self, from: data))
            } catch {
                issues.append(SessionLoadIssue(
                    directoryName: directory.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        issues.sort { $0.directoryName < $1.directoryName }
        return SessionListing(sessions: sessions, issues: issues)
    }

    public func remove(id: UUID) async throws {
        let directory = directory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionStoreError.invalidSessionDirectory
        }
        try fileManager.removeItem(at: directory)
    }

    public func append(event: CalibrationEvent, sessionID: UUID) async throws {
        let directory = directory(for: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        let record = PersistedCalibrationEvent(event)
        var data = try eventEncoder().encode(record)
        data.append(0x0A)
        let eventURL = directory.appending(path: "events.jsonl")
        if !fileManager.fileExists(atPath: eventURL.path) {
            guard fileManager.createFile(atPath: eventURL.path, contents: nil) else {
                throw SessionStoreError.invalidSessionDirectory
            }
        }
        let handle = try FileHandle(forWritingTo: eventURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func sessionDirectory(for id: UUID) async -> URL {
        directory(for: id)
    }

    private func directory(for id: UUID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func write(
        _ session: CalibrationSession,
        to url: URL,
        updatingTimestamp: Bool
    ) throws {
        var current = session
        if updatingTimestamp {
            // Saving is a durable mutation. Advance an ordinary stale timestamp,
            // but never move a caller-supplied timestamp backwards if the wall
            // clock changed or the record was prepared with a later value.
            current.updatedAt = max(current.updatedAt, Date())
        }
        try encoder().encode(current).write(to: url, options: [.atomic])
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601String(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(fromISO8601: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO 8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }

    private func eventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601String(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(fromISO8601 value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withInternetDateTime]
        return legacy.date(from: value)
    }
}

private struct PersistedCalibrationEvent: Codable {
    var timestamp = Date()
    var kind: String
    var message: String
    var completed: Int?
    var total: Int?
    var artifact: SessionArtifact?
    var measurement: Measurement?
    var verification: VerificationReport?
    var actionID: String?

    init(_ event: CalibrationEvent) {
        switch event {
        case .stageChanged(let stage):
            kind = "stage"
            message = stage.rawValue
        case .message(let value):
            kind = "message"
            message = value
        case .measurement(let value):
            kind = "measurement"
            message = "Measurement captured"
            measurement = value
        case .progress(let value, let maximum):
            kind = "progress"
            message = maximum.map { "\(value) of \($0)" } ?? "\(value)"
            completed = value
            total = maximum
        case .userActionRequired(let request):
            kind = "action-required"
            message = request.message
            actionID = request.id
        case .artifactCreated(let value):
            kind = "artifact"
            message = value.kind
            artifact = value
        case .warning(let value):
            kind = "warning"
            message = value
        case .technicalLog(let value):
            timestamp = value.timestamp
            kind = value.level
            message = value.message
        case .verificationCompleted(let report):
            kind = "verification"
            message = "Verification completed"
            verification = report
        }
    }
}
