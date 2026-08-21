import Foundation
import Testing
@testable import LumaCore

@Suite
struct FileSessionStoreTests {
    @Test
    func testCreateAndLoadRoundTripCompleteSession() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let session = completeSession()

        let directory = try await store.create(session)
        let loaded = try await store.load(id: session.id)

        #expect(directory == root.appending(path: session.id.uuidString, directoryHint: .isDirectory))
        #expect(await store.sessionDirectory(for: session.id) == directory)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "session.json").path))
        #expect(loaded.id == session.id)
        #expect(loaded.schemaVersion == CalibrationSession.schemaVersion)
        #expect(loaded.state == .completed)
        #expect(loaded.display == session.display)
        #expect(loaded.instrument == session.instrument)
        #expect(loaded.target == session.target)
        #expect(loaded.correction == session.correction)
        #expect(loaded.measurementMode == session.measurementMode)
        #expect(loaded.characterizationPreset == session.characterizationPreset)
        #expect(loaded.plannedCharacterizationPatchCount == session.plannedCharacterizationPatchCount)
        #expect(loaded.actualCharacterizationPatchCount == session.actualCharacterizationPatchCount)
        #expect(loaded.profileModel == session.profileModel)
        #expect(loaded.environment == session.environment)
        #expect(loaded.setupMeasurement == session.setupMeasurement)
        #expect(loaded.artifacts == session.artifacts)
        #expect(loaded.profileGenerationCompletedAt == session.profileGenerationCompletedAt)
        #expect(loaded.activationVerificationAttempt == session.activationVerificationAttempt)
        #expect(loaded.verification == session.verification)
        #expect(loaded.verificationAssessment == session.verificationAssessment)
        #expect(loaded.installation == session.installation)
        #expect(loaded.failureMessage == nil)
        #expect(loaded.createdAt == session.createdAt)
        #expect(loaded.updatedAt == session.updatedAt)
    }

    @Test
    func saveAdvancesAnOrdinaryStaleUpdateTimestampWithoutChangingCreationTime() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let priorUpdate = Date(timeIntervalSince1970: 1_700_000_100)
        var session = CalibrationSession(
            id: UUID(),
            createdAt: createdAt,
            updatedAt: priorUpdate,
            state: .preflighting
        )
        _ = try await store.create(session)

        session.state = .calibrating
        try await store.save(session)
        let loaded = try await store.load(id: session.id)

        #expect(loaded.createdAt == createdAt)
        #expect(loaded.updatedAt > priorUpdate)
        #expect(loaded.state == .calibrating)
    }

    @Test
    func saveDoesNotMoveALaterCallerSuppliedTimestampBackward() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let futureUpdate = Date(timeIntervalSince1970: 4_000_000_000)
        let session = CalibrationSession(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: futureUpdate,
            state: .completed
        )
        _ = try await store.create(session)

        try await store.save(session)
        let loaded = try await store.load(id: session.id)

        #expect(loaded.updatedAt == futureUpdate)
    }

    @Test
    func legacyInstallationRecordWithoutActivationStatusDecodesAsActive() throws {
        let installedAt = Date(timeIntervalSince1970: 1_700_000_150)
        let record = ProfileInstallationRecord(
            displayFingerprint: "legacy-display",
            installedProfileURL: URL(fileURLWithPath: "/synthetic/legacy-after.icc"),
            previousProfileURL: URL(fileURLWithPath: "/synthetic/legacy-before.icc"),
            installedAt: installedAt
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "activationStatus")
        object.removeValue(forKey: "activatedAt")

        let decoded = try JSONDecoder().decode(
            ProfileInstallationRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.activationStatus == .active)
        #expect(decoded.activatedAt == installedAt)
    }

    @Test
    func legacySessionWithoutMeasurementEffortFieldsDecodesWithNilValues() throws {
        let encoded = try JSONEncoder().encode(completeSession())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "characterizationPreset")
        object.removeValue(forKey: "plannedCharacterizationPatchCount")
        object.removeValue(forKey: "actualCharacterizationPatchCount")
        object.removeValue(forKey: "profileModel")

        let decoded = try JSONDecoder().decode(
            CalibrationSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.characterizationPreset == nil)
        #expect(decoded.plannedCharacterizationPatchCount == nil)
        #expect(decoded.actualCharacterizationPatchCount == nil)
        #expect(decoded.profileModel == nil)
    }

    @Test
    func legacySessionWithoutOutcomeFieldsDecodesWithNilValues() throws {
        let encoded = try JSONEncoder().encode(completeSession())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "profileGenerationCompletedAt")
        object.removeValue(forKey: "activationVerificationAttempt")
        object.removeValue(forKey: "verificationAssessment")

        let decoded = try JSONDecoder().decode(
            CalibrationSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.profileGenerationCompletedAt == nil)
        #expect(decoded.activationVerificationAttempt == nil)
        #expect(decoded.verificationAssessment == nil)
        #expect(decoded.verification != nil)
    }

    @Test
    func testSaveReplacesCanonicalJSONAndLeavesNoPartialSibling() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        var session = CalibrationSession(id: UUID(), state: .preflighting)
        let directory = try await store.create(session)

        session.state = .calibrating
        session.failureMessage = "synthetic replacement marker"
        try await store.save(session)

        let loaded = try await store.load(id: session.id)
        #expect(loaded.state == .calibrating)
        #expect(loaded.failureMessage == "synthetic replacement marker")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.hasPrefix("session.json") } == ["session.json"])
        let raw = try Data(contentsOf: directory.appending(path: "session.json"))
        _ = try JSONSerialization.jsonObject(with: raw)
    }

    @Test
    func testConcurrentSavesNeverExposeTruncatedJSON() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let concurrentReader = FileSessionStore(rootDirectory: root)
        let id = UUID()
        let session = CalibrationSession(id: id, state: .preflighting)
        let directory = try await store.create(session)
        let sessionURL = directory.appending(path: "session.json")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<100 {
                    var replacement = session
                    replacement.state = index.isMultiple(of: 2) ? .calibrating : .characterizing
                    replacement.failureMessage = String(repeating: "x", count: index * 257)
                    try await store.save(replacement)
                    await Task.yield()
                }
            }
            group.addTask {
                for _ in 0..<300 {
                    let data = try Data(contentsOf: sessionURL)
                    guard
                        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let encodedID = object["id"] as? String,
                        UUID(uuidString: encodedID) == id
                    else {
                        throw SyntheticTestError("Observed another session identity")
                    }

                    // A separate store actor exercises the production decoder while
                    // the writer is replacing the canonical file. JSONDecoder's
                    // built-in `.iso8601` strategy did not accept fractional seconds
                    // on older Foundation versions, while the store intentionally
                    // accepts both fractional and legacy whole-second timestamps.
                    let decoded = try await concurrentReader.load(id: id)
                    guard decoded.id == id else {
                        throw SyntheticTestError("Store decoded another session identity")
                    }
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func testListSkipsCorruptEntriesAndSortsNewestFirst() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let first = CalibrationSession(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .completed
        )
        let second = CalibrationSession(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_010),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
            state: .failed,
            failureMessage: "synthetic"
        )
        _ = try await store.create(first)
        _ = try await store.create(second)

        let corruptDirectory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("{ definitely-not-json".utf8).write(to: corruptDirectory.appending(path: "session.json"))

        let sessions = try await store.list()
        #expect(sessions.map(\.id) == [second.id, first.id])

        let listing = try await store.listing()
        #expect(listing.sessions.map(\.id) == [second.id, first.id])
        #expect(listing.issues.count == 1)
        #expect(listing.issues.first?.directoryName == corruptDirectory.lastPathComponent)
    }

    @Test
    func listUsesCreationTimeThenSessionIDAsDeterministicTieBreakers() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let sharedUpdate = Date(timeIntervalSince1970: 1_700_000_100)
        let earlierCreation = Date(timeIntervalSince1970: 1_700_000_000)
        let laterCreation = Date(timeIntervalSince1970: 1_700_000_050)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let sessions = [
            CalibrationSession(id: olderID, createdAt: earlierCreation, updatedAt: sharedUpdate),
            CalibrationSession(id: secondID, createdAt: laterCreation, updatedAt: sharedUpdate),
            CalibrationSession(id: firstID, createdAt: laterCreation, updatedAt: sharedUpdate),
        ]
        for session in sessions {
            _ = try await store.create(session)
        }

        let expected = [firstID, secondID, olderID]
        #expect(try await store.list().map(\.id) == expected)
        #expect(try await store.list().map(\.id) == expected)
    }

    @Test
    func removeDeletesOnlyRequestedSessionDirectory() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let removed = CalibrationSession(id: UUID(), state: .completed)
        let retained = CalibrationSession(id: UUID(), state: .completed)
        let removedDirectory = try await store.create(removed)
        let retainedDirectory = try await store.create(retained)

        try await store.remove(id: removed.id)

        #expect(!FileManager.default.fileExists(atPath: removedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: retainedDirectory.path))
        #expect(try await store.list().map(\.id) == [retained.id])
    }

    @Test
    func testListOnMissingRootIsEmptyAndMissingLoadIsTyped() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        TestSupport.removeTemporaryDirectory(root)
        let store = FileSessionStore(rootDirectory: root)
        #expect(try await store.list() == [])

        let missingID = UUID()
        do {
            _ = try await store.load(id: missingID)
            Issue.record("Expected missing session")
        } catch SessionStoreError.sessionNotFound(let id) {
            #expect(id == missingID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testAppendWritesIndependentNewlineDelimitedEventRecords() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let session = CalibrationSession(id: UUID())
        let directory = try await store.create(session)
        let artifact = SessionArtifact(kind: "Synthetic calibration", url: directory.appending(path: "test.cal"))
        let report = VerificationReport(metrics: verificationMetrics(), rawOutput: "synthetic verification")
        let events: [CalibrationEvent] = [
            .stageChanged(.calibrating),
            .message("Synthetic message"),
            .progress(completed: 7, total: 12),
            .artifactCreated(artifact),
            .warning("Synthetic warning"),
            .technicalLog(LogRecord(level: "debug", message: "Synthetic diagnostic")),
            .verificationCompleted(report),
        ]
        for event in events {
            try await store.append(event: event, sessionID: session.id)
        }

        let data = try Data(contentsOf: directory.appending(path: "events.jsonl"))
        #expect(data.last == 0x0A)
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == events.count)
        let objects = try lines.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
        #expect(objects.compactMap { $0["kind"] as? String } == [
            "stage", "message", "progress", "artifact", "warning", "debug", "verification",
        ])
        #expect(objects[2]["completed"] as? Int == 7)
        #expect(objects[2]["total"] as? Int == 12)
        #expect(objects[3]["artifact"] != nil)
        #expect(objects[6]["verification"] != nil)
    }

    @Test
    func testConcurrentAppendDoesNotLoseOrJoinRecords() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let session = CalibrationSession(id: UUID())
        let directory = try await store.create(session)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try await store.append(event: .message("message-\(index)"), sessionID: session.id)
                }
            }
            try await group.waitForAll()
        }

        let data = try Data(contentsOf: directory.appending(path: "events.jsonl"))
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == 50)
        let messages = try Set(lines.map { line -> String in
            let object = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            return try #require(object["message"] as? String)
        })
        #expect(messages == Set((0..<50).map { "message-\($0)" }))
    }

    @Test
    func testAppendToMissingSessionIsTypedFailure() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let id = UUID()

        do {
            try await store.append(event: .message("never written"), sessionID: id)
            Issue.record("Expected missing session")
        } catch SessionStoreError.sessionNotFound(let reported) {
            #expect(reported == id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func completeSession() -> CalibrationSession {
        let correctionURL = URL(fileURLWithPath: "/tmp/synthetic-test.ccss")
        return CalibrationSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .completed,
            display: TestSupport.display(),
            instrument: TestSupport.instrument(),
            target: CalibrationTarget(
                name: "Synthetic custom target",
                whitePoint: .chromaticity(.init(x: 0.31, y: 0.33)),
                luminanceCDM2: 110,
                transferFunction: .bt1886,
                blackPointMode: .optimize,
                quality: .high,
                correctionID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"),
                patchGeometry: .init(
                    widthFraction: 0.3,
                    heightFraction: 0.4,
                    horizontalPosition: 0.45,
                    verticalPosition: 0.55
                ),
                displayModeNote: "Synthetic test note"
            ),
            correction: TestSupport.correction(at: correctionURL),
            measurementMode: .nonRefresh,
            characterizationPreset: .high,
            plannedCharacterizationPatchCount: CharacterizationPreset.high.requestedPatchCount,
            actualCharacterizationPatchCount: 476,
            profileModel: .lut,
            environment: EnvironmentSnapshot(
                engineVersion: "3.5.0-synthetic",
                engineDirectory: URL(fileURLWithPath: "/tmp/synthetic-argyll/bin"),
                toolStatus: ["dispcal": true, "spotread": true],
                engineDiagnostic: "Synthetic test engine probe",
                operatingSystem: "Synthetic macOS test value",
                appVersion: "0-test"
            ),
            setupMeasurement: Measurement(
                xyz: XYZColor(x: 112, y: 118, z: 108),
                chromaticity: Chromaticity(x: 0.3314, y: 0.3491),
                luminanceCDM2: 118,
                correlatedColorTemperature: 6_200,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_120),
                rawSource: "Synthetic before white-patch reading"
            ),
            artifacts: [
                SessionArtifact(
                    id: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA")!,
                    kind: "ICC profile",
                    url: URL(fileURLWithPath: "/tmp/synthetic.icc"),
                    sha256: String(repeating: "b", count: 64),
                    isComplete: true
                ),
            ],
            profileGenerationCompletedAt: Date(timeIntervalSince1970: 1_700_000_140),
            activationVerificationAttempt: ActivationVerificationAttempt(
                id: UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB")!,
                status: .verified,
                startedAt: Date(timeIntervalSince1970: 1_700_000_145),
                profileActivatedAt: Date(timeIntervalSince1970: 1_700_000_150),
                verificationStartedAt: Date(timeIntervalSince1970: 1_700_000_160),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                restoredBeforeProfile: false
            ),
            verification: VerificationReport(
                metrics: verificationMetrics(),
                rawOutput: "Synthetic verification output",
                measuredAt: Date(timeIntervalSince1970: 1_700_000_200)
            ),
            verificationAssessment: VerificationCriteria.applicationDefault.assessment(
                for: verificationMetrics(),
                targetLuminance: 110,
                targetGamma: nil,
                evaluatedAt: Date(timeIntervalSince1970: 1_700_000_201)
            ),
            installation: ProfileInstallationRecord(
                displayFingerprint: "synthetic-display-fingerprint",
                installedProfileURL: URL(fileURLWithPath: "/tmp/synthetic.icc"),
                previousProfileURL: URL(fileURLWithPath: "/tmp/previous.icc"),
                installedAt: Date(timeIntervalSince1970: 1_700_000_150)
            )
        )
    }

    private func verificationMetrics() -> VerificationMetrics {
        VerificationMetrics(
            averageDeltaE2000: 0.7,
            percentile95DeltaE2000: 1.4,
            maximumDeltaE2000: 2.1,
            whitePointDeltaE2000: 0.6,
            measuredWhite: .init(x: 0.3128, y: 0.3291),
            luminanceCDM2: 119.5,
            blackLevelCDM2: 0.11,
            contrastRatio: 1_086,
            measuredGamma: 2.19,
            gammaRMSError: 0.012,
            warnings: ["Synthetic warning"]
        )
    }
}

struct SyntheticTestError: Error, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
