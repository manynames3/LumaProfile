import Foundation
import Testing
@testable import LumaCore

@Suite
struct CalibrationWorkflowTests {
    @Test
    func successfulGenerationPersistsProvenanceHashesAndLeavesProfileInactive() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let stream = await workflow.run(request())
        let observation = await observe(stream)

        #expect(!observation.hadError)
        #expect(observation.stages == [
            .calibrating,
            .characterizing,
            .generatingPatchSet,
            .buildingProfile,
            .completed,
        ])
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.measurementMode == .auto)
        #expect(final.characterizationPreset == .standard)
        #expect(final.plannedCharacterizationPatchCount == 220)
        #expect(final.actualCharacterizationPatchCount == 220)
        #expect(final.profileModel == .shaperMatrix)
        #expect(final.environment?.engineVersion == "3.5.0-synthetic")
        #expect(final.environment?.engineDirectory == URL(fileURLWithPath: "/synthetic/argyll/bin"))
        #expect(final.environment?.toolStatus["dispcal"] == true)
        #expect(final.environment?.engineDiagnostic == "Synthetic coherent engine probe")
        #expect(final.environment?.operatingSystem.isEmpty == false)
        #expect(final.artifacts.map(\.kind) == ["calibration", "characterization measurements", "ICC profile"])
        #expect(final.artifacts.last?.sha256 == WorkflowFakeEngine.profileHash)
        #expect(final.profileBaseline?.displayFingerprint == TestSupport.display().fingerprint)
        #expect(final.profileBaseline?.activeProfileURL == URL(fileURLWithPath: "/synthetic/previous.icc"))
        #expect(final.setupMeasurement?.luminanceCDM2 == 117)
        #expect(final.profileGenerationCompletedAt != nil)
        #expect(final.activationVerificationAttempt == nil)
        #expect(final.installation == nil)
        #expect(final.verification == nil)
        #expect(final.verificationAssessment == nil)
        #expect(final.failureMessage == nil)

        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .completed)
        #expect(persisted.environment == final.environment)
        #expect(persisted.measurementMode == .auto)
        #expect(persisted.characterizationPreset == .standard)
        #expect(persisted.plannedCharacterizationPatchCount == 220)
        #expect(persisted.actualCharacterizationPatchCount == 220)
        #expect(persisted.profileModel == .shaperMatrix)
        #expect(persisted.artifacts.last?.sha256 == WorkflowFakeEngine.profileHash)
        #expect(persisted.profileBaseline == final.profileBaseline)
        #expect(persisted.profileGenerationCompletedAt == final.profileGenerationCompletedAt)
        #expect(persisted.activationVerificationAttempt == nil)
        #expect(persisted.installation == nil)
        #expect(persisted.verification == nil)
        #expect(persisted.verificationAssessment == nil)

        let engineState = await engine.snapshot()
        #expect(engineState.probeCount == 1)
        #expect(engineState.displayValidationCount == 2)
        #expect(engineState.calibrationCount == 1)
        #expect(engineState.characterizationCount == 1)
        #expect(engineState.characterizationPreset == .standard)
        #expect(engineState.characterizationPatchGeometry == PatchGeometry(
            widthFraction: 0.3,
            heightFraction: 0.2,
            horizontalPosition: 0.4,
            verticalPosition: 0.6
        ))
        #expect(engineState.buildCount == 1)
        #expect(engineState.verificationCount == 0)
        #expect(engineState.restorationCount == 1)
        #expect(engineState.buildMetadata["displayFingerprint"] == TestSupport.display().fingerprint)
        #expect(engineState.buildMetadata["instrumentID"] == TestSupport.instrument().id)
        #expect(engineState.buildMetadata["characterizationPreset"] == CharacterizationPreset.standard.rawValue)
        #expect(engineState.buildMetadata["characterizationPatches"] == "220")
        #expect(engineState.buildMetadata["characterizationSamples"] == nil)
        #expect(engineState.verificationProfileURL == nil)
        let installerState = await installer.snapshot()
        #expect(installerState.installCount == 0)
        #expect(installerState.rollbackCount == 0)
    }

    @Test
    func generationOnlyLeavesBeforeProfileActiveAndPersistsAfterCandidate() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let observation = await observe(await workflow.run(request()))

        #expect(!observation.hadError)
        #expect(observation.stages == [
            .calibrating,
            .characterizing,
            .generatingPatchSet,
            .buildingProfile,
            .completed,
        ])
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.profileGenerationCompletedAt != nil)
        #expect(final.activationVerificationAttempt == nil)
        #expect(final.installation == nil)
        #expect(final.verification == nil)
        #expect(final.profileBaseline?.displayFingerprint == TestSupport.display().fingerprint)
        #expect(final.profileBaseline?.activeProfileURL == URL(fileURLWithPath: "/synthetic/previous.icc"))
        #expect(final.artifacts.last?.url.pathExtension.lowercased() == "icc")
        #expect((await installer.snapshot()).installCount == 0)
        let engineState = await engine.snapshot()
        #expect(engineState.verificationCount == 0)
        #expect(engineState.restorationCount == 1)

        let persisted = try await store.load(id: final.id)
        #expect(persisted.installation == nil)
        #expect(persisted.profileBaseline == final.profileBaseline)
        #expect(persisted.artifacts.last?.url == final.artifacts.last?.url)
    }

    @Test
    func failedGenerationRestoreRetriesInFreshTaskAndPersistsHonestFailure() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .restorationFailure)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let observation = await observe(await workflow.run(request()))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("synthetic VideoLUT restoration failure") == true)
        let final = try #require(observation.lastSession)
        #expect(final.state == .interrupted)
        #expect(final.profileGenerationCompletedAt != nil)
        #expect(final.installation == nil)
        #expect(final.failureMessage?.contains("previously active display calibration could not be reloaded") == true)
        #expect((await engine.snapshot()).restorationCount == 2)
        #expect((await installer.snapshot()).installCount == 0)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .interrupted)
        #expect(persisted.failureMessage == final.failureMessage)
    }

    @Test
    func meterDisconnectAfterCalibrationStopsBeforeCharacterizationAndRestoresDisplay() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .instrumentDisconnectsAfterCalibration)
        let workflow = CalibrationWorkflow(
            engine: engine,
            installer: WorkflowFakeInstaller(),
            store: store
        )

        let observation = await observe(await workflow.run(request()))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("disconnected after calibration") == true)
        let final = try #require(observation.lastSession)
        #expect(final.state == .failed)
        #expect(final.failureMessage?.contains("disconnected after calibration") == true)
        let engineState = await engine.snapshot()
        #expect(engineState.calibrationCount == 1)
        #expect(engineState.characterizationCount == 0)
        #expect(engineState.restorationCount == 1)
    }

    @Test
    func meterDisconnectBeforeVerificationRestoresBeforeAndRetainsCandidate() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .instrumentDisconnectsBeforeVerification)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)

        let activation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(activation.hadError)
        #expect(activation.errorDescription?.contains("disconnected before verification") == true)
        let final = try #require(activation.lastSession)
        #expect(final.state == .completed)
        #expect(final.installation == nil)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.profileGenerationCompletedAt == generated.profileGenerationCompletedAt)
        #expect((await engine.snapshot()).verificationCount == 0)
        #expect((await installer.snapshot()).rollbackCount == 1)
    }

    @Test
    func activationOnlyLeavesTheProfileActiveWithoutMeasuring() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        // The meter is gone before verification; activation alone must not need it.
        let engine = WorkflowFakeEngine(scenario: .instrumentDisconnectsBeforeVerification)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)

        let activation = await observe(await workflow.activateAndVerify(session: generated, verify: false))

        #expect(!activation.hadError)
        let final = try #require(activation.lastSession)
        #expect(final.state == .completed)
        #expect(final.installation?.activationStatus == .active)
        #expect(final.activationVerificationAttempt?.status == .activated)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == false)
        #expect(final.verification == nil)
        #expect((await engine.snapshot()).verificationCount == 0)
        #expect((await installer.snapshot()).rollbackCount == 0)
    }

    @Test
    func explicitActivationAndVerificationRunsOnlyAfterGenerationCompletes() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)

        let activation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(!activation.hadError)
        #expect(activation.stages == [.installingProfile, .verifying, .completed])
        let final = try #require(activation.lastSession)
        #expect(final.installation?.activationStatus == .active)
        #expect(final.installation?.previousProfileURL == generated.profileBaseline?.activeProfileURL)
        #expect(final.profileGenerationCompletedAt == generated.profileGenerationCompletedAt)
        #expect(final.activationVerificationAttempt?.status == .verified)
        #expect(final.activationVerificationAttempt?.profileActivatedAt != nil)
        #expect(final.activationVerificationAttempt?.verificationStartedAt != nil)
        #expect(final.activationVerificationAttempt?.finishedAt != nil)
        #expect(final.activationVerificationAttempt?.errorMessage == nil)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == false)
        #expect(final.verification != nil)
        #expect(final.verificationAssessment?.criteriaVersion == VerificationCriteria.applicationDefaultVersion)
        #expect(final.verificationAssessment?.criteria == .applicationDefault)
        #expect(final.verificationAssessment?.rating == .excellent)
        #expect(final.verificationAssessment?.reasons.isEmpty == false)
        #expect((await installer.snapshot()).installCount == 1)
        let engineState = await engine.snapshot()
        #expect(engineState.displayValidationCount == 4)
        #expect(engineState.verificationCount == 1)
        #expect(engineState.restorationCount == 1)
    }

    @Test
    func explicitActivationPersistsPendingRecoveryBeforeChangingColorSync() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(blockActivation: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)

        let activationTask = Task {
            await observe(await workflow.activateAndVerify(session: generated))
        }
        try await waitUntil("activation entry") {
            await installer.snapshot().activationHasEntered
        }

        let journaled = try await store.load(id: generated.id)
        #expect(journaled.installation?.activationStatus == .activationPending)
        #expect(journaled.installation?.previousProfileURL == generated.profileBaseline?.activeProfileURL)
        #expect(journaled.activationVerificationAttempt?.status == .inProgress)
        #expect(journaled.activationVerificationAttempt?.startedAt != nil)
        #expect(journaled.activationVerificationAttempt?.finishedAt == nil)

        await installer.releaseActivation()
        let activation = await activationTask.value
        #expect(!activation.hadError)
        #expect(activation.lastSession?.installation?.activationStatus == .active)
    }

    @Test
    func tamperedGeneratedProfileFailsClosedBeforeInstallerMutation() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let profile = try #require(generated.artifacts.last { $0.kind == "ICC profile" })
        try Data("Tampered after generation\n".utf8).write(to: profile.url, options: .atomic)

        let activation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(activation.hadError)
        #expect(activation.errorDescription?.contains("no longer matches its recorded SHA-256") == true)
        let final = try #require(activation.lastSession)
        #expect(final.state == .failed)
        #expect(final.failureMessage?.contains("no longer matches its recorded SHA-256") == true)
        #expect(final.profileGenerationCompletedAt != nil)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.errorMessage?.contains("no longer matches") == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.installation == nil)
        #expect(final.artifacts.first(where: { $0.id == profile.id })?.isComplete == false)
        let installerState = await installer.snapshot()
        #expect(installerState.prepareCount == 0)
        #expect(installerState.installCount == 0)
        #expect(installerState.rollbackCount == 0)
        #expect((await engine.snapshot()).verificationCount == 0)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .failed)
        #expect(persisted.artifacts.first(where: { $0.id == profile.id })?.isComplete == false)
        #expect(persisted.failureMessage == final.failureMessage)
    }

    @Test
    func calibrationFailurePersistsFailedSessionAndDoesNotInstallOrRollback() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .calibrationFailure)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let observation = await observe(await workflow.run(request()))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("synthetic calibration failure") == true)
        let final = try #require(observation.lastSession)
        #expect(final.state == .failed)
        #expect(final.failureMessage?.contains("synthetic calibration failure") == true)
        #expect(final.installation == nil)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .failed)
        #expect(persisted.failureMessage == final.failureMessage)
        let installerState = await installer.snapshot()
        #expect(installerState.installCount == 0)
        #expect(installerState.rollbackCount == 0)
        #expect((await engine.snapshot()).restorationCount == 1)
    }

    @Test
    func disconnectedSelectedMeterFailsBeforeCreatingCalibrationSession() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .instrumentUnavailable)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let observation = await observe(await workflow.run(request()))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("selected i1Display is no longer available") == true)
        #expect(observation.lastSession == nil)
        #expect(try await store.list().isEmpty)
        let engineState = await engine.snapshot()
        #expect(engineState.calibrationCount == 0)
    }

    @Test
    func verificationFailureRollsBackPreviousProfileAndKeepsCandidateCompleted() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .verificationFailure)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let observation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(observation.hadError)
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.profileGenerationCompletedAt == generated.profileGenerationCompletedAt)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.finishedAt != nil)
        #expect(final.activationVerificationAttempt?.errorMessage?.contains("synthetic verification failure") == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfileAt != nil)
        #expect(final.installation == nil)
        #expect(final.failureMessage == nil)
        #expect(final.verification == nil)
        #expect(final.verificationAssessment == nil)
        #expect(observation.errorDescription?.contains("synthetic verification failure") == true)
        #expect(observation.warnings.contains { $0.contains("Before profile was restored") })
        let installerState = await installer.snapshot()
        #expect(installerState.installCount == 1)
        #expect(installerState.rollbackCount == 1)
        #expect(installerState.lastRollbackFingerprint == TestSupport.display().fingerprint)
        #expect((await engine.snapshot()).restorationCount == 2)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .completed)
        #expect(persisted.installation == nil)
        #expect(persisted.activationVerificationAttempt == final.activationVerificationAttempt)
    }

    @Test
    func verificationWithoutAReportIsFailedAndRestoredInsteadOfMarkedVerified() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .emptyVerification)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let observation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("without producing a complete result") == true)
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.verification == nil)
        #expect(final.verificationAssessment == nil)
        #expect(final.installation == nil)
        #expect((await installer.snapshot()).rollbackCount == 1)
    }

    @Test
    func failedAutomaticRollbackRetainsInstallationRecordForManualRecovery() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .verificationFailure)
        let installer = WorkflowFakeInstaller(failRollback: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let observation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(observation.hadError)
        let final = try #require(observation.lastSession)
        #expect(final.state == .interrupted)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.errorMessage?.contains("synthetic verification failure") == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == false)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfileAt == nil)
        #expect(final.installation != nil)
        #expect(final.installation?.activationStatus == .restorationRequired)
        #expect(final.failureMessage?.contains("synthetic verification failure") == true)
        #expect(observation.warnings.contains { $0.contains("Automatic rollback or calibration reload failed") })
        #expect(observation.warnings.contains { $0.contains("Restore Before") })
        #expect((await installer.snapshot()).rollbackCount >= 1)
        #expect((await engine.snapshot()).restorationCount == 1)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.installation == final.installation)
    }

    @Test
    func unverifiedActivationRetainsRecoveryRecordUntilWorkflowRollbackSucceeds() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(failAfterActivation: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)

        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let observation = await observe(await workflow.activateAndVerify(session: generated))

        #expect(observation.hadError)
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.activationVerificationAttempt?.status == .failed)
        #expect(final.activationVerificationAttempt?.errorMessage?.contains("synthetic activation readback failure") == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.installation == nil)
        #expect(final.failureMessage == nil)
        #expect(observation.errorDescription?.contains("synthetic activation readback failure") == true)
        #expect(observation.warnings.contains { $0.contains("Before profile was restored") })
        let installerState = await installer.snapshot()
        #expect(installerState.installCount == 1)
        #expect(installerState.rollbackCount == 1)
        #expect((await engine.snapshot()).restorationCount == 2)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.installation == nil)
    }

    @Test
    func cancellationDuringExplicitVerificationRollsBackAndKeepsGeneratedSessionCompleted() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .waitForVerificationCancellation)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let stream = await workflow.activateAndVerify(session: generated)
        let observationTask = Task { await observe(stream) }

        try await waitUntil("verification stream started") {
            await engine.snapshot().verificationCount == 1
        }
        await workflow.cancel()
        let observation = await observationTask.value

        #expect(!observation.hadError)
        let final = try #require(observation.lastSession)
        #expect(final.state == .completed)
        #expect(final.activationVerificationAttempt?.status == .cancelled)
        #expect(final.activationVerificationAttempt?.errorMessage?.contains("cancelled") == true)
        #expect(final.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(final.installation == nil)
        #expect(observation.stages.suffix(2) == [.verifying, .completed])
        #expect(observation.warnings.contains { $0.contains("Before profile was restored") })
        #expect((await engine.snapshot()).cancelCount >= 1)
        #expect((await engine.snapshot()).restorationCount == 2)
        #expect((await installer.snapshot()).rollbackCount == 1)
        let persisted = try await store.load(id: final.id)
        #expect(persisted.state == .completed)
        #expect(persisted.installation == nil)
    }

    @Test
    func promptGatedWorkflowDoesNotAdvanceBeforeMatchingExplicitAcknowledgment() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let engine = WorkflowFakeEngine(scenario: .promptGatedCalibration)
        let installer = WorkflowFakeInstaller()
        let store = FileSessionStore(rootDirectory: root)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let stream = await workflow.run(request())
        let observationTask = Task { await observe(stream) }

        try await waitUntil("calibration prompt pending") {
            await engine.snapshot().pendingPromptID != nil
        }
        var engineState = await engine.snapshot()
        #expect(engineState.acknowledgedPromptIDs.isEmpty)
        #expect(engineState.characterizationCount == 0)

        do {
            try await workflow.acknowledgeUserAction(id: "synthetic-wrong-prompt")
            Issue.record("Expected mismatched acknowledgment rejection")
        } catch ArgyllEngineError.unsafePrompt {
            // Expected.
        }
        engineState = await engine.snapshot()
        #expect(engineState.acknowledgedPromptIDs.isEmpty)
        #expect(engineState.characterizationCount == 0)

        let expectedID = try #require(engineState.pendingPromptID)
        try await workflow.acknowledgeUserAction(id: expectedID)
        let observation = await observationTask.value

        #expect(!observation.hadError)
        #expect(observation.userActionIDs == [expectedID])
        #expect(observation.lastSession?.state == .completed)
        engineState = await engine.snapshot()
        #expect(engineState.acknowledgedPromptIDs == [expectedID])
        #expect(engineState.characterizationCount == 1)
    }

    @Test
    func cancellationDuringGenerationReloadsBeforeCalibrationInFreshCleanupTask() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let engine = WorkflowFakeEngine(scenario: .promptGatedCalibration)
        let installer = WorkflowFakeInstaller()
        let store = FileSessionStore(rootDirectory: root)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let observationTask = Task { await observe(await workflow.run(request())) }

        try await waitUntil("calibration prompt pending") {
            await engine.snapshot().pendingPromptID != nil
        }
        await workflow.cancel()
        let observation = await observationTask.value

        #expect(!observation.hadError)
        #expect(observation.lastSession?.state == .cancelled)
        #expect((await engine.snapshot()).restorationCount == 1)
        #expect((await installer.snapshot()).installCount == 0)
    }

    @Test
    func reconcileThenRestoreBeforeRecoversGenerationOnlyInterruptedSession() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let display = TestSupport.display()
        let session = CalibrationSession(
            id: UUID(),
            state: .characterizing,
            display: display,
            profileBaseline: DisplayProfileBaseline(
                displayFingerprint: display.fingerprint,
                activeProfileURL: URL(fileURLWithPath: "/synthetic/previous.icc")
            )
        )
        let directory = try await store.create(session)

        let reconciled = try await workflow.reconcileInterruptedSessions()
        let interrupted = try #require(reconciled.first(where: { $0.id == session.id }))

        #expect(interrupted.state == .interrupted)
        #expect(interrupted.installation == nil)
        #expect(interrupted.failureMessage?.contains("Restore Before") == true)

        let restored = try await workflow.restoreBefore(session: interrupted)

        #expect(restored.state == .cancelled)
        #expect(restored.failureMessage == nil)
        #expect(restored.installation == nil)
        let engineState = await engine.snapshot()
        #expect(engineState.restorationCount == 1)
        #expect(engineState.lastRestorationDirectory == directory)
        let installerState = await installer.snapshot()
        #expect(installerState.prepareCount == 0)
        #expect(installerState.installCount == 0)
        #expect(installerState.rollbackCount == 0)
        let persisted = try await store.load(id: session.id)
        #expect(persisted.state == .cancelled)
        #expect(persisted.failureMessage == nil)
    }

    @Test
    func reconcileMarksAnUnfinishedActivationAttemptAsFailedWithUnknownRecovery() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let workflow = CalibrationWorkflow(
            engine: WorkflowFakeEngine(scenario: .success),
            installer: WorkflowFakeInstaller(),
            store: store
        )
        let attempt = ActivationVerificationAttempt(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            profileActivatedAt: Date(timeIntervalSince1970: 1_700_000_310),
            verificationStartedAt: Date(timeIntervalSince1970: 1_700_000_320)
        )
        let session = CalibrationSession(
            id: UUID(),
            state: .verifying,
            activationVerificationAttempt: attempt
        )
        _ = try await store.create(session)

        let reconciled = try await workflow.reconcileInterruptedSessions()
        let interrupted = try #require(reconciled.first(where: { $0.id == session.id }))

        #expect(interrupted.state == .interrupted)
        #expect(interrupted.activationVerificationAttempt?.status == .failed)
        #expect(interrupted.activationVerificationAttempt?.finishedAt != nil)
        #expect(interrupted.activationVerificationAttempt?.errorMessage?.contains("ended before display restoration") == true)
        #expect(interrupted.activationVerificationAttempt?.restoredBeforeProfile == nil)
    }

    @Test
    func restoreBeforeResolvesGenerationRecoveryWithoutTouchingAChangedAssociation() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(
            currentProfileURL: URL(fileURLWithPath: "/synthetic/unrelated-current.icc")
        )
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let display = TestSupport.display()
        let session = CalibrationSession(
            id: UUID(),
            state: .interrupted,
            display: display,
            profileBaseline: DisplayProfileBaseline(
                displayFingerprint: display.fingerprint,
                activeProfileURL: URL(fileURLWithPath: "/synthetic/previous.icc")
            ),
            failureMessage: "Synthetic interrupted generation"
        )
        _ = try await store.create(session)

        let recovered = try await workflow.restoreBefore(session: session)

        // Only the current profile's calibration is reloaded; the association
        // is left exactly as macOS has it.
        #expect(recovered.state == .cancelled)
        #expect((await engine.snapshot()).restorationCount == 1)
        let installerState = await installer.snapshot()
        #expect(installerState.prepareCount == 0)
        #expect(installerState.installCount == 0)
        #expect(installerState.rollbackCount == 0)
        let persisted = try await store.load(id: session.id)
        #expect(persisted.state == .cancelled)
    }

    @Test
    func explicitRollbackClearsPersistedInstallationOnlyAfterInstallerSucceeds() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let activation = await observe(await workflow.activateAndVerify(session: generated))
        let completed = try #require(activation.lastSession)
        #expect(completed.installation?.activationStatus == .active)

        let rolledBack = try await workflow.rollback(session: completed)

        #expect(rolledBack.installation == nil)
        #expect(rolledBack.activationVerificationAttempt?.status == .verified)
        #expect(rolledBack.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(rolledBack.activationVerificationAttempt?.restoredBeforeProfileAt != nil)
        #expect((await installer.snapshot()).rollbackCount == 1)
        #expect((await engine.snapshot()).restorationCount == 2)
        let persisted = try await store.load(id: rolledBack.id)
        #expect(persisted.installation == nil)
    }

    @Test
    func explicitRestorePersistsRecoveryMarkerBeforeChangingDisplayState() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(blockRollback: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let activated = try #require(
            (await observe(await workflow.activateAndVerify(session: generated))).lastSession
        )

        let restoreTask = Task {
            try await workflow.restoreBefore(session: activated)
        }
        try await waitUntil("rollback entry") {
            await installer.snapshot().rollbackHasEntered
        }

        let writeAhead = try await store.load(id: activated.id)
        #expect(writeAhead.state == .completed)
        #expect(writeAhead.installation?.activationStatus == .restorationRequired)

        await installer.releaseRollback()
        let restored = try await restoreTask.value
        #expect(restored.installation == nil)
        let persistedRestored = try await store.load(id: activated.id)
        #expect(persistedRestored.installation == nil)
    }

    @Test
    func failedExplicitRestorePersistsInterruptedRecoveryForRelaunch() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(failRollback: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let activated = try #require(
            (await observe(await workflow.activateAndVerify(session: generated))).lastSession
        )
        #expect(activated.installation?.activationStatus == .active)

        do {
            _ = try await workflow.restoreBefore(session: activated)
            Issue.record("Expected Restore Before to preserve a durable recovery record")
        } catch {
            #expect(error.localizedDescription.contains("synthetic rollback failure"))
        }

        let persisted = try await store.load(id: activated.id)
        #expect(persisted.state == .interrupted)
        #expect(persisted.installation?.activationStatus == .restorationRequired)
        #expect(persisted.activationVerificationAttempt?.restoredBeforeProfile == false)
        #expect(persisted.failureMessage?.contains("Restore Before failed") == true)
        #expect((await installer.snapshot()).rollbackCount == 1)
    }

    @Test
    func failedExplicitRestoreSurfacesRecoveryPersistenceFailure() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = RecoveryPersistenceFailingStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller(failRollback: true)
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        let generated = try #require((await observe(await workflow.run(request()))).lastSession)
        let activated = try #require(
            (await observe(await workflow.activateAndVerify(session: generated))).lastSession
        )

        do {
            _ = try await workflow.restoreBefore(session: activated)
            Issue.record("Expected the failed recovery-state save to be surfaced")
        } catch CalibrationWorkflowError.protectedStatePersistenceFailed(
            let operationFailure,
            let persistenceFailure
        ) {
            #expect(operationFailure.contains("synthetic rollback failure"))
            #expect(persistenceFailure.contains("synthetic recovery persistence failure"))
        }

        // The write-ahead marker remains durable even though the later failure
        // update could not be saved.
        let persisted = try await store.load(id: activated.id)
        #expect(persisted.state == .completed)
        #expect(persisted.installation?.activationStatus == .restorationRequired)
    }

    @Test
    func successfulManualRecoveryReturnsInterruptedActivationToCompletedCandidate() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let engine = WorkflowFakeEngine(scenario: .success)
        let installer = WorkflowFakeInstaller()
        let workflow = CalibrationWorkflow(engine: engine, installer: installer, store: store)
        var interrupted = try #require((await observe(await workflow.run(request()))).lastSession)
        let candidate = try #require(interrupted.artifacts.first { artifact in
            artifact.isComplete && artifact.url.pathExtension.lowercased() == "icc"
        })
        interrupted.state = .interrupted
        interrupted.failureMessage = "synthetic rollback was not confirmed"
        interrupted.installation = ProfileInstallationRecord(
            displayFingerprint: try #require(interrupted.display).fingerprint,
            installedProfileURL: candidate.url,
            previousProfileURL: URL(fileURLWithPath: "/synthetic/previous.icc"),
            installedAt: Date(timeIntervalSince1970: 1_700_000_300),
            activationStatus: .restorationRequired
        )
        interrupted.activationVerificationAttempt = ActivationVerificationAttempt(
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_301),
            errorMessage: "synthetic verification failure",
            restoredBeforeProfile: false
        )
        try await store.save(interrupted)

        let recovered = try await workflow.restoreBefore(session: interrupted)

        #expect(recovered.state == .completed)
        #expect(recovered.installation == nil)
        #expect(recovered.failureMessage == nil)
        #expect(recovered.activationVerificationAttempt?.status == .failed)
        #expect(recovered.activationVerificationAttempt?.restoredBeforeProfile == true)
        #expect(recovered.activationVerificationAttempt?.restoredBeforeProfileAt != nil)
        let persisted = try await store.load(id: recovered.id)
        #expect(persisted.state == .completed)
        #expect(persisted.installation == nil)
        #expect((await installer.snapshot()).rollbackCount == 1)
        #expect((await engine.snapshot()).restorationCount == 2)
    }

    @Test
    func explicitActivationRejectsIncompleteSessionBeforeMutation() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let store = FileSessionStore(rootDirectory: root)
        let workflow = CalibrationWorkflow(
            engine: WorkflowFakeEngine(scenario: .success),
            installer: WorkflowFakeInstaller(),
            store: store
        )
        let incomplete = CalibrationSession(state: .buildingProfile)

        let observation = await observe(await workflow.activateAndVerify(session: incomplete))

        #expect(observation.hadError)
        #expect(observation.errorDescription?.contains("Only a completed calibration profile") == true)
        #expect(observation.lastSession == nil)
        #expect(try await store.list().isEmpty)
    }

    private func request() -> CalibrationWorkflowRequest {
        var target = CalibrationTarget.photography
        target.patchGeometry = PatchGeometry(
            widthFraction: 0.3,
            heightFraction: 0.2,
            horizontalPosition: 0.4,
            verticalPosition: 0.6
        )
        return CalibrationWorkflowRequest(
            display: TestSupport.display(),
            instrument: TestSupport.instrument(),
            target: target,
            measurementMode: .auto,
            setupMeasurement: Measurement(
                xyz: XYZColor(x: 111, y: 117, z: 109),
                chromaticity: Chromaticity(x: 0.3294, y: 0.3472),
                luminanceCDM2: 117,
                correlatedColorTemperature: 6_300,
                rawSource: "Synthetic setup measurement"
            ),
            characterization: .standard,
            profileModel: .shaperMatrix,
            profileDescription: "Synthetic workflow profile"
        )
    }
}

private struct WorkflowObservation: Sendable {
    var stages: [WorkflowStage] = []
    var warnings: [String] = []
    var userActionIDs: [String] = []
    var lastSession: CalibrationSession?
    var directory: URL?
    var hadError = false
    var errorDescription: String?
}

private func observe(
    _ stream: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>
) async -> WorkflowObservation {
    var result = WorkflowObservation()
    do {
        for try await update in stream {
            switch update {
            case .sessionCreated(let session, let directory):
                result.lastSession = session
                result.directory = directory
            case .sessionUpdated(let session):
                result.lastSession = session
            case .event(let event):
                switch event {
                case .stageChanged(let stage): result.stages.append(stage)
                case .warning(let warning): result.warnings.append(warning)
                case .userActionRequired(let request): result.userActionIDs.append(request.id)
                default: break
                }
            }
        }
    } catch {
        result.hadError = true
        result.errorDescription = error.localizedDescription
    }
    return result
}

private func waitUntil(
    _ description: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SyntheticTestError("Timed out waiting for \(description)")
}

private struct SyntheticWorkflowFailure: Error, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

private actor WorkflowFakeEngine: CalibrationEngine {
    static let profileBytes = Data("Synthetic deterministic ICC profile bytes\n".utf8)
    static let profileHash = LumaSHA256.hexDigest(profileBytes)

    enum Scenario: Sendable {
        case success
        case calibrationFailure
        case verificationFailure
        case emptyVerification
        case waitForVerificationCancellation
        case promptGatedCalibration
        case instrumentUnavailable
        case instrumentDisconnectsAfterCalibration
        case instrumentDisconnectsBeforeVerification
        case restorationFailure
    }

    struct Snapshot: Sendable {
        var probeCount: Int
        var displayValidationCount: Int
        var calibrationCount: Int
        var characterizationCount: Int
        var buildCount: Int
        var verificationCount: Int
        var restorationCount: Int
        var lastRestorationDirectory: URL?
        var characterizationPreset: CharacterizationPreset?
        var characterizationPatchGeometry: PatchGeometry?
        var buildMetadata: [String: String]
        var verificationProfileURL: URL?
        var acknowledgedPromptIDs: [String]
        var pendingPromptID: String?
        var cancelCount: Int
    }

    nonisolated let scenario: Scenario
    private var probeCount = 0
    private var displayValidationCount = 0
    private var instrumentDiscoveryCount = 0
    private var calibrationCount = 0
    private var characterizationCount = 0
    private var buildCount = 0
    private var verificationCount = 0
    private var restorationCount = 0
    private var lastRestorationDirectory: URL?
    private var characterizationPreset: CharacterizationPreset?
    private var characterizationPatchGeometry: PatchGeometry?
    private var buildMetadata: [String: String] = [:]
    private var verificationProfileURL: URL?
    private var acknowledgedPromptIDs: [String] = []
    private var pendingPromptID: String?
    private var cancelCount = 0
    private var promptCalibrationContinuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation?
    private var promptCalibrationRequest: CalibrationRequest?
    private var waitingVerificationContinuation: AsyncThrowingStream<VerificationEvent, Error>.Continuation?

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func probe() async -> EngineProbe {
        probeCount += 1
        return EngineProbe(
            isAvailable: true,
            version: "3.5.0-synthetic",
            directory: URL(fileURLWithPath: "/synthetic/argyll/bin"),
            toolStatus: ["dispcal": true, "dispread": true, "colprof": true, "profcheck": true],
            diagnostic: "Synthetic coherent engine probe"
        )
    }

    func discoverInstruments() async throws -> [InstrumentDescriptor] {
        instrumentDiscoveryCount += 1
        if case .instrumentUnavailable = scenario { return [] }
        if case .instrumentDisconnectsAfterCalibration = scenario,
           instrumentDiscoveryCount >= 2 { return [] }
        if case .instrumentDisconnectsBeforeVerification = scenario,
           instrumentDiscoveryCount >= 4 { return [] }
        return [TestSupport.instrument()]
    }

    func validateDisplayMapping(for display: PhysicalDisplay) async throws {
        displayValidationCount += 1
    }

    func measure(_ request: SpotMeasurementRequest) async throws -> LumaCore.Measurement {
        LumaCore.Measurement(
            xyz: .init(x: 19.01, y: 20, z: 21.78),
            chromaticity: .d65,
            luminanceCDM2: 20,
            rawSource: "Synthetic fake-engine measurement"
        )
    }

    nonisolated func calibrate(
        _ request: CalibrationRequest
    ) -> AsyncThrowingStream<CalibrationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.beginCalibration(request, continuation: continuation) }
        }
    }

    nonisolated func characterize(
        _ request: CharacterizationRequest
    ) -> AsyncThrowingStream<CharacterizationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.beginCharacterization(request, continuation: continuation) }
        }
    }

    func buildProfile(_ request: ProfileBuildRequest) async throws -> ICCProfileArtifact {
        buildCount += 1
        buildMetadata = request.metadata
        try Self.profileBytes.write(to: request.outputURL, options: .atomic)
        return ICCProfileArtifact(
            url: request.outputURL,
            model: request.model,
            sizeBytes: Int64(Self.profileBytes.count),
            sha256: Self.profileHash,
            validationMessages: ["Synthetic fake profile validated"]
        )
    }

    nonisolated func verify(
        _ request: VerificationRequest
    ) -> AsyncThrowingStream<VerificationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.beginVerification(request, continuation: continuation) }
        }
    }

    func restoreActiveProfileCalibration(
        for display: PhysicalDisplay,
        sessionDirectory: URL
    ) async throws {
        restorationCount += 1
        lastRestorationDirectory = sessionDirectory
        if case .restorationFailure = scenario {
            throw SyntheticWorkflowFailure(message: "synthetic VideoLUT restoration failure")
        }
    }

    func acknowledgeUserAction(id: String) async throws {
        guard id == pendingPromptID,
              let continuation = promptCalibrationContinuation,
              let request = promptCalibrationRequest else {
            throw ArgyllEngineError.unsafePrompt("Synthetic mismatched prompt acknowledgment: \(id)")
        }
        acknowledgedPromptIDs.append(id)
        pendingPromptID = nil
        promptCalibrationContinuation = nil
        promptCalibrationRequest = nil
        continuation.yield(.artifactCreated(calibrationArtifact(for: request)))
        continuation.finish()
    }

    func cancelCurrentOperation() async {
        cancelCount += 1
        promptCalibrationContinuation?.finish(throwing: CancellationError())
        waitingVerificationContinuation?.finish(throwing: CancellationError())
        promptCalibrationContinuation = nil
        promptCalibrationRequest = nil
        waitingVerificationContinuation = nil
        pendingPromptID = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            probeCount: probeCount,
            displayValidationCount: displayValidationCount,
            calibrationCount: calibrationCount,
            characterizationCount: characterizationCount,
            buildCount: buildCount,
            verificationCount: verificationCount,
            restorationCount: restorationCount,
            lastRestorationDirectory: lastRestorationDirectory,
            characterizationPreset: characterizationPreset,
            characterizationPatchGeometry: characterizationPatchGeometry,
            buildMetadata: buildMetadata,
            verificationProfileURL: verificationProfileURL,
            acknowledgedPromptIDs: acknowledgedPromptIDs,
            pendingPromptID: pendingPromptID,
            cancelCount: cancelCount
        )
    }

    private func beginCalibration(
        _ request: CalibrationRequest,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) {
        calibrationCount += 1
        switch scenario {
        case .calibrationFailure:
            continuation.finish(throwing: SyntheticWorkflowFailure(message: "synthetic calibration failure"))
        case .promptGatedCalibration:
            let id = "synthetic-place-meter"
            pendingPromptID = id
            promptCalibrationContinuation = continuation
            promptCalibrationRequest = request
            continuation.yield(.userActionRequired(.init(id: id, message: "Place synthetic meter")))
        default:
            continuation.yield(.progress(completed: 1, total: 1))
            continuation.yield(.artifactCreated(calibrationArtifact(for: request)))
            continuation.finish()
        }
    }

    private func beginCharacterization(
        _ request: CharacterizationRequest,
        continuation: AsyncThrowingStream<CharacterizationEvent, Error>.Continuation
    ) {
        characterizationCount += 1
        characterizationPreset = request.preset
        characterizationPatchGeometry = request.patchGeometry
        continuation.yield(.stageChanged(.generatingPatchSet))
        continuation.yield(.progress(completed: 0, total: request.preset.requestedPatchCount))
        continuation.yield(.artifactCreated(SessionArtifact(
            kind: "characterization measurements",
            url: request.sessionDirectory.appending(path: "synthetic.ti3"),
            sha256: String(repeating: "c", count: 64)
        )))
        continuation.finish()
    }

    private func beginVerification(
        _ request: VerificationRequest,
        continuation: AsyncThrowingStream<VerificationEvent, Error>.Continuation
    ) {
        verificationCount += 1
        verificationProfileURL = request.profileURL
        switch scenario {
        case .verificationFailure:
            continuation.finish(throwing: SyntheticWorkflowFailure(message: "synthetic verification failure"))
        case .emptyVerification:
            continuation.finish()
        case .waitForVerificationCancellation:
            waitingVerificationContinuation = continuation
        default:
            continuation.yield(.verificationCompleted(Self.verificationReport()))
            continuation.finish()
        }
    }

    private func calibrationArtifact(for request: CalibrationRequest) -> SessionArtifact {
        SessionArtifact(
            kind: "calibration",
            url: request.sessionDirectory.appending(path: "synthetic.cal"),
            sha256: String(repeating: "a", count: 64)
        )
    }

    private static func verificationReport() -> VerificationReport {
        VerificationReport(
            metrics: VerificationMetrics(
                averageDeltaE2000: 0.75,
                percentile95DeltaE2000: 1.4,
                maximumDeltaE2000: 2.1,
                whitePointDeltaE2000: 0.6,
                measuredWhite: .d65,
                luminanceCDM2: 120,
                blackLevelCDM2: 0.1,
                contrastRatio: 1_200,
                measuredGamma: 2.2,
                gammaRMSError: 0.01
            ),
            rawOutput: "Synthetic fake verification output",
            measuredAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
    }
}

private actor RecoveryPersistenceFailingStore: SessionStore {
    private let base: FileSessionStore

    init(rootDirectory: URL) {
        base = FileSessionStore(rootDirectory: rootDirectory)
    }

    func create(_ session: CalibrationSession) async throws -> URL {
        try await base.create(session)
    }

    func save(_ session: CalibrationSession) async throws {
        if session.state == .interrupted {
            throw SyntheticWorkflowFailure(message: "synthetic recovery persistence failure")
        }
        try await base.save(session)
    }

    func load(id: UUID) async throws -> CalibrationSession {
        try await base.load(id: id)
    }

    func list() async throws -> [CalibrationSession] {
        try await base.list()
    }

    func append(event: CalibrationEvent, sessionID: UUID) async throws {
        try await base.append(event: event, sessionID: sessionID)
    }

    func sessionDirectory(for id: UUID) async -> URL {
        await base.sessionDirectory(for: id)
    }
}

private actor WorkflowFakeInstaller: ProfileInstaller {
    struct Snapshot: Sendable {
        var prepareCount: Int
        var installCount: Int
        var rollbackCount: Int
        var lastRollbackFingerprint: String?
        var activationHasEntered: Bool
        var rollbackHasEntered: Bool
    }

    let failRollback: Bool
    let failAfterActivation: Bool
    let blockActivation: Bool
    let blockRollback: Bool
    let currentProfileURL: URL?
    private var prepareCount = 0
    private var installCount = 0
    private var rollbackCount = 0
    private var lastRollbackFingerprint: String?
    private var activationHasEntered = false
    private var rollbackHasEntered = false
    private var activationContinuation: CheckedContinuation<Void, Never>?
    private var rollbackContinuation: CheckedContinuation<Void, Never>?

    init(
        failRollback: Bool = false,
        failAfterActivation: Bool = false,
        blockActivation: Bool = false,
        blockRollback: Bool = false,
        currentProfileURL: URL? = URL(fileURLWithPath: "/synthetic/previous.icc")
    ) {
        self.failRollback = failRollback
        self.failAfterActivation = failAfterActivation
        self.blockActivation = blockActivation
        self.blockRollback = blockRollback
        self.currentProfileURL = currentProfileURL
    }

    func currentProfile(for display: PhysicalDisplay) async throws -> URL? {
        currentProfileURL
    }

    func prepareActivation(
        profileURL: URL,
        for display: PhysicalDisplay,
        expectedCurrentProfileURL: URL?
    ) async throws -> ProfileInstallationRecord {
        prepareCount += 1
        return ProfileInstallationRecord(
            displayFingerprint: display.fingerprint,
            installedProfileURL: profileURL,
            previousProfileURL: expectedCurrentProfileURL,
            installedAt: Date(timeIntervalSince1970: 1_700_000_300),
            activationStatus: .activationPending
        )
    }

    func activate(
        _ record: ProfileInstallationRecord,
        for display: PhysicalDisplay
    ) async throws {
        installCount += 1
        activationHasEntered = true
        if blockActivation {
            await withCheckedContinuation { continuation in
                activationContinuation = continuation
            }
        }
        if failAfterActivation {
            var recoveryRecord = record
            recoveryRecord.activationStatus = .restorationRequired
            throw SyntheticRecoverableInstallationFailure(recoveryRecord: recoveryRecord)
        }
    }

    func releaseActivation() {
        activationContinuation?.resume()
        activationContinuation = nil
    }

    func rollback(_ record: ProfileInstallationRecord, for display: PhysicalDisplay) async throws {
        rollbackCount += 1
        lastRollbackFingerprint = display.fingerprint
        rollbackHasEntered = true
        if blockRollback {
            await withCheckedContinuation { continuation in
                rollbackContinuation = continuation
            }
        }
        if failRollback {
            throw SyntheticWorkflowFailure(message: "synthetic rollback failure")
        }
    }

    func releaseRollback() {
        rollbackContinuation?.resume()
        rollbackContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCount: prepareCount,
            installCount: installCount,
            rollbackCount: rollbackCount,
            lastRollbackFingerprint: lastRollbackFingerprint,
            activationHasEntered: activationHasEntered,
            rollbackHasEntered: rollbackHasEntered
        )
    }
}

private struct SyntheticRecoverableInstallationFailure: LocalizedError, Sendable, ProfileInstallationRecoveryProviding {
    let recoveryRecord: ProfileInstallationRecord

    var errorDescription: String? { "synthetic activation readback failure" }
}


@Suite
struct ProfileNamingTests {
    @Test
    func profileFilenameIncludesLocalDateAndCollapsesSeparators() throws {
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-11-23 04:39 UTC is still 22 November in New York.
        let date = Date(timeIntervalSince1970: 1_795_408_740)

        let name = CalibrationWorkflow.profileFilename(
            displayName: "DELL S3221QS",
            targetName: "sRGB / D65 / 120 / Gamma 2.2",
            date: date,
            timeZone: timeZone
        )

        #expect(name == "DELL-S3221QS-sRGB-D65-120-Gamma-2-2-2026-11-22.icc")
    }
}
