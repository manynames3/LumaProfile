@preconcurrency import ColorSync
import CoreGraphics
import Foundation

public enum ProfileInstallerError: LocalizedError, Sendable {
    case displayDisconnected
    case displayIdentityChanged
    case invalidProfile(String)
    case cannotCreateProfileDirectory(String)
    case cannotCopyProfile(String)
    case currentProfileLookupFailed(String)
    case profileAssociationChanged
    case associationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .displayDisconnected:
            "The selected display is no longer connected. No profile was changed."
        case .displayIdentityChanged:
            "The selected display identity changed. Re-select it before installing a profile."
        case .invalidProfile(let detail):
            "The generated ICC profile is invalid: \(detail)"
        case .cannotCreateProfileDirectory(let detail):
            "The user ColorSync profile folder could not be created: \(detail)"
        case .cannotCopyProfile(let detail):
            "The profile could not be copied into the user ColorSync folder: \(detail)"
        case .currentProfileLookupFailed(let detail):
            "ColorSync could not read the selected display's current profile: \(detail). No profile was changed."
        case .profileAssociationChanged:
            "The selected display's active profile changed after it was captured. No profile was replaced; review the current association before trying again."
        case .associationFailed:
            "ColorSync could not associate the profile with the selected display."
        case .rollbackFailed:
            "ColorSync could not restore the selected display's previous profile."
        }
    }
}

public struct ProfileActivationUnverifiedError: LocalizedError, Sendable, ProfileInstallationRecoveryProviding {
    public let recoveryRecord: ProfileInstallationRecord

    public init(recoveryRecord: ProfileInstallationRecord) {
        self.recoveryRecord = recoveryRecord
    }

    public var errorDescription: String? {
        "ColorSync changed the profile association, but neither activation nor restoration could be verified. The recovery record was retained for another rollback attempt."
    }
}

/// Installs into the current user's ColorSync repository and associates only the
/// explicitly selected display UUID. It never requests administrator privileges.
public actor MacProfileInstaller: ProfileInstaller, ProfileComparisonSwitching {
    private let fileManager: FileManager
    private let inventory: any DisplayInventory
    private let profileDirectory: URL

    public init(
        inventory: any DisplayInventory = MacDisplayInventory(),
        fileManager: FileManager = .default,
        profileDirectory: URL? = nil
    ) {
        self.inventory = inventory
        self.fileManager = fileManager
        self.profileDirectory = profileDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "ColorSync/Profiles/LumaProfile", directoryHint: .isDirectory)
    }

    public func currentProfile(for display: PhysicalDisplay) async throws -> URL? {
        try await validateIdentity(of: display)
        guard let unmanagedProfile = ColorSyncProfileCreateWithDisplayID(display.cgDisplayID) else {
            return nil
        }
        let profile = unmanagedProfile.takeRetainedValue()
        var error: Unmanaged<CFError>?
        let unmanagedURL = ColorSyncProfileGetURL(profile, &error)
        let url = unmanagedURL.map { $0.takeUnretainedValue() as URL }
        let failureDescription = error?.takeRetainedValue().localizedDescription
        return try Self.checkedProfileURL(url, failureDescription: failureDescription)
    }

    /// Kept separate from the ColorSync call so the important distinction
    /// between "no URL is associated" and "ColorSync failed to retrieve it"
    /// remains deterministic and unit-testable.
    static func checkedProfileURL(_ url: URL?, failureDescription: String?) throws -> URL? {
        if let url { return url }
        if let failureDescription {
            throw ProfileInstallerError.currentProfileLookupFailed(failureDescription)
        }
        return nil
    }

    public func prepareActivation(
        profileURL: URL,
        for display: PhysicalDisplay,
        expectedCurrentProfileURL: URL?
    ) async throws -> ProfileInstallationRecord {
        try await validateIdentity(of: display)
        let previousURL = try await currentProfile(for: display)
        guard sameAssociation(previousURL, expectedCurrentProfileURL) else {
            throw ProfileInstallerError.profileAssociationChanged
        }
        try validateProfile(at: profileURL)

        do {
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        } catch {
            throw ProfileInstallerError.cannotCreateProfileDirectory(error.localizedDescription)
        }

        let destination = uniqueDestination(for: profileURL)
        let installationRecord = ProfileInstallationRecord(
            displayFingerprint: display.fingerprint,
            installedProfileURL: destination,
            previousProfileURL: previousURL,
            activationStatus: .activationPending
        )
        do {
            try fileManager.copyItem(at: profileURL, to: destination)
        } catch {
            throw ProfileInstallerError.cannotCopyProfile(error.localizedDescription)
        }
        return installationRecord
    }

    public func activate(
        _ record: ProfileInstallationRecord,
        for display: PhysicalDisplay
    ) async throws {
        guard record.displayFingerprint == display.fingerprint else {
            throw ProfileInstallerError.displayIdentityChanged
        }
        try await validateIdentity(of: display)
        try validateProfile(at: record.installedProfileURL)

        let currentURL = try await currentProfile(for: display)
        if sameAssociation(currentURL, record.installedProfileURL) { return }
        guard sameAssociation(currentURL, record.previousProfileURL) else {
            removeInstalledCandidateIfOwned(at: record.installedProfileURL)
            throw ProfileInstallerError.profileAssociationChanged
        }

        do {
            try setProfile(record.installedProfileURL, for: display, failure: .associationFailed)
        } catch {
            removeInstalledCandidateIfOwned(at: record.installedProfileURL)
            throw error
        }

        // Reloads calibration tables from each display's already-associated
        // ColorSync profile. Association itself remains scoped to `display`.
        CGDisplayRestoreColorSyncSettings()
        guard await verifyAssociation(record.installedProfileURL, for: display) else {
            var restorationVerified = false
            do {
                try setProfile(record.previousProfileURL, for: display, failure: .rollbackFailed)
                CGDisplayRestoreColorSyncSettings()
                restorationVerified = await verifyAssociation(
                    record.previousProfileURL,
                    for: display,
                    disallowing: record.installedProfileURL
                )
            } catch {
                restorationVerified = false
            }
            if restorationVerified {
                removeInstalledCandidateIfOwned(at: record.installedProfileURL)
                throw ProfileInstallerError.associationFailed
            }
            var recoveryRecord = record
            recoveryRecord.activationStatus = .restorationRequired
            throw ProfileActivationUnverifiedError(recoveryRecord: recoveryRecord)
        }
    }

    public func rollback(_ record: ProfileInstallationRecord, for display: PhysicalDisplay) async throws {
        guard record.displayFingerprint == display.fingerprint else {
            throw ProfileInstallerError.displayIdentityChanged
        }
        try await validateIdentity(of: display)
        let currentURL = try await currentProfile(for: display)
        if record.previousProfileURL == nil {
            if currentURL == nil {
                CGDisplayRestoreColorSyncSettings()
                await removeInstalledCandidateAfterSuccessfulRollback(record, for: display)
                return
            }
            if let currentURL, !equivalent(currentURL, record.installedProfileURL) {
                CGDisplayRestoreColorSyncSettings()
                await removeInstalledCandidateAfterSuccessfulRollback(record, for: display)
                return
            }
        } else if sameAssociation(currentURL, record.previousProfileURL) {
            // The association may already be Before while a temporary or
            // interrupted calibration is still loaded. Reload ColorSync state
            // before reporting idempotent rollback success.
            CGDisplayRestoreColorSyncSettings()
            await removeInstalledCandidateAfterSuccessfulRollback(record, for: display)
            return
        }
        guard sameAssociation(currentURL, record.installedProfileURL) else {
            throw ProfileInstallerError.profileAssociationChanged
        }
        try setProfile(record.previousProfileURL, for: display, failure: .rollbackFailed)
        CGDisplayRestoreColorSyncSettings()
        guard await verifyAssociation(
            record.previousProfileURL,
            for: display,
            disallowing: record.installedProfileURL
        ) else {
            throw ProfileInstallerError.rollbackFailed
        }
        await removeInstalledCandidateAfterSuccessfulRollback(record, for: display)
    }

    /// Moves the display between the two profiles this activation recorded so
    /// the operator can compare them by eye. It refuses to act when the display
    /// is currently on any other profile, never removes a file, and leaves the
    /// session's activation record untouched.
    public func showComparison(
        _ side: ProfileComparisonSide,
        record: ProfileInstallationRecord,
        for display: PhysicalDisplay
    ) async throws {
        guard record.displayFingerprint == display.fingerprint else {
            throw ProfileInstallerError.displayIdentityChanged
        }
        try await validateIdentity(of: display)
        let currentURL = try await currentProfile(for: display)
        guard sameAssociation(currentURL, record.installedProfileURL)
            || sameAssociation(currentURL, record.previousProfileURL) else {
            throw ProfileInstallerError.profileAssociationChanged
        }

        let targetURL: URL?
        switch side {
        case .before:
            targetURL = record.previousProfileURL
        case .after:
            try validateProfile(at: record.installedProfileURL)
            targetURL = record.installedProfileURL
        }
        if !sameAssociation(currentURL, targetURL) {
            try setProfile(targetURL, for: display, failure: .associationFailed)
        }
        CGDisplayRestoreColorSyncSettings()
        guard await verifyAssociation(
            targetURL,
            for: display,
            disallowing: side == .before ? record.installedProfileURL : nil
        ) else {
            throw ProfileInstallerError.associationFailed
        }
    }

    private func validateIdentity(of display: PhysicalDisplay) async throws {
        let connected = try await inventory.displays()
        guard connected.contains(where: { $0.cgDisplayID == display.cgDisplayID }) else {
            throw ProfileInstallerError.displayDisconnected
        }
        guard connected.contains(where: {
            $0.cgDisplayID == display.cgDisplayID && $0.fingerprint == display.fingerprint
        }) else {
            throw ProfileInstallerError.displayIdentityChanged
        }
    }

    private func validateProfile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProfileInstallerError.invalidProfile("The file does not exist.")
        }
        var error: Unmanaged<CFError>?
        guard let unmanagedProfile = ColorSyncProfileCreateWithURL(url as CFURL, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "ColorSync rejected the file."
            throw ProfileInstallerError.invalidProfile(detail)
        }
        _ = unmanagedProfile.takeRetainedValue()
    }

    private func uniqueDestination(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        return profileDirectory.appending(path: "\(base)-\(suffix).icc")
    }

    /// Removes only an inactive candidate copied into LumaProfile's own
    /// ColorSync directory and carrying the filename shape generated by
    /// `uniqueDestination(for:)`. A fresh association lookup deliberately
    /// fails closed: lookup errors, reconnect races, symlinks, directories,
    /// nested paths, and foreign filenames all leave the file untouched.
    private func removeInstalledCandidateAfterSuccessfulRollback(
        _ record: ProfileInstallationRecord,
        for display: PhysicalDisplay
    ) async {
        guard Self.isOwnedInstalledCandidate(
            record.installedProfileURL,
            in: profileDirectory
        ) else {
            return
        }

        do {
            let activeURL = try await currentProfile(for: display)
            guard !sameAssociation(activeURL, record.installedProfileURL) else { return }
            removeInstalledCandidateIfOwned(at: record.installedProfileURL)
        } catch {
            // Rollback already succeeded. Cleanup is intentionally best-effort
            // and must never turn a restored display into a reported failure.
        }
    }

    static func isOwnedInstalledCandidate(
        _ candidate: URL,
        in profileDirectory: URL
    ) -> Bool {
        guard candidate.isFileURL, profileDirectory.isFileURL else { return false }

        let candidateURL = candidate.standardizedFileURL
        guard let values = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return false
        }

        let expectedParent = profileDirectory.resolvingSymlinksInPath().standardizedFileURL
        let actualParent = candidateURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard actualParent == expectedParent,
              candidateURL.pathExtension.lowercased() == "icc"
        else {
            return false
        }

        let stem = candidateURL.deletingPathExtension().lastPathComponent
        guard let separator = stem.lastIndex(of: "-") else { return false }
        let suffix = stem[stem.index(after: separator)...].utf8
        guard suffix.count == 8 else { return false }
        return suffix.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func removeInstalledCandidateIfOwned(at candidate: URL) {
        _ = Self.removeOwnedInstalledCandidate(
            candidate,
            from: profileDirectory,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func removeOwnedInstalledCandidate(
        _ candidate: URL,
        from profileDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isOwnedInstalledCandidate(candidate, in: profileDirectory) else { return false }
        do {
            try fileManager.removeItem(at: candidate)
            return true
        } catch {
            return false
        }
    }

    private func setProfile(
        _ url: URL?,
        for display: PhysicalDisplay,
        failure: ProfileInstallerError
    ) throws {
        guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(display.cgDisplayID)?.takeRetainedValue() else {
            throw ProfileInstallerError.displayDisconnected
        }

        guard
            let defaultProfileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
            let userScopeKey = kColorSyncProfileUserScope?.takeUnretainedValue(),
            let hostScopeKey = kColorSyncProfileHostScope?.takeUnretainedValue(),
            let displayClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue()
        else {
            throw failure
        }
        let profileValue: Any = url.map { $0 as CFURL } ?? kCFNull!
        let values: NSDictionary = [
            defaultProfileKey as String: profileValue,
            userScopeKey as String: kCFPreferencesCurrentUser,
            hostScopeKey as String: kCFPreferencesCurrentHost,
        ]
        guard ColorSyncDeviceSetCustomProfiles(
            displayClass,
            displayUUID,
            values
        ) else {
            throw failure
        }
    }

    private func verifyAssociation(
        _ expectedURL: URL?,
        for display: PhysicalDisplay,
        disallowing forbiddenURL: URL? = nil
    ) async -> Bool {
        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            do {
                let activeURL = try await currentProfile(for: display)
                if let expectedURL, let activeURL {
                    if equivalent(activeURL, expectedURL) { return true }
                } else if expectedURL == nil, let activeURL {
                    if forbiddenURL.map({ !equivalent(activeURL, $0) }) ?? true { return true }
                } else if expectedURL == nil, activeURL == nil {
                    return true
                }
            } catch { continue }
        }
        return false
    }

    private func equivalent(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    private func sameAssociation(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): equivalent(lhs, rhs)
        default: false
        }
    }
}
