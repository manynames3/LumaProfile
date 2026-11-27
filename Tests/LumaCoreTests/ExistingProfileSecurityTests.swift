import Foundation
import Testing
@testable import LumaCore

/// Synthetic ICC-shaped bytes: a 128-byte header, one tag entry and a
/// table-form vcgt with two entries per channel. Not a complete profile.
private func syntheticProfile(curveEnd: UInt16, description: String = "LumaProfile") -> Data {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes += [0, 0, 0, 1]                                  // tag count
    bytes += Array("vcgt".utf8) + [0, 0, 0, 144] + [0, 0, 0, 30]
    bytes += Array("vcgt".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0] // signature, reserved, table type
    bytes += [0, 3, 0, 2, 0, 2]                            // 3 channels, 2 entries, 2 bytes
    for _ in 0..<3 { bytes += [0, 0, UInt8(curveEnd >> 8), UInt8(curveEnd & 0xFF)] }
    bytes += Array(description.utf8)
    return Data(bytes)
}

@Suite
struct ExistingProfileSecurityTests {
    @Test
    func classifiesHealthyArgyllTemporaryAndBlackProfiles() {
        #expect(ExistingProfileSecurity.condition(of: syntheticProfile(curveEnd: 61_000)) == .healthy)
        #expect(ExistingProfileSecurity.condition(of: syntheticProfile(curveEnd: 0)) == .blackCurve)
        #expect(ExistingProfileSecurity.condition(of: syntheticProfile(curveEnd: 61_000, description: "Dispwin Temp")) == .argyllTemporaryCopy)
        #expect(ExistingProfileSecurity.condition(of: Data("no vcgt here".utf8)) == .healthy)
    }

    @Test
    func locksHealthyProfilesAndQuarantinesDamagedOnes() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer {
            if let names = try? FileManager.default.subpathsOfDirectory(atPath: root.path) {
                for name in names {
                    try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: root.appending(path: name).path)
                }
            }
            TestSupport.removeTemporaryDirectory(root)
        }
        let profiles = root.appending(path: "Profiles", directoryHint: .isDirectory)
        let quarantine = root.appending(path: "Quarantine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try syntheticProfile(curveEnd: 61_000).write(to: profiles.appending(path: "Good.icc"))
        try syntheticProfile(curveEnd: 0).write(to: profiles.appending(path: "Black.icc"))
        try syntheticProfile(curveEnd: 61_000, description: "Dispwin Temp").write(to: profiles.appending(path: "Swapped.icc"))
        try Data("notes".utf8).write(to: profiles.appending(path: "readme.txt"))

        let report = ExistingProfileSecurity.secure(profileDirectory: profiles, quarantineDirectory: quarantine)

        #expect(report.locked.map(\.lastPathComponent) == ["Good.icc"])
        #expect(Set(report.quarantined.map(\.lastPathComponent)) == ["Black.icc", "Swapped.icc"])
        let goodAttributes = try FileManager.default.attributesOfItem(atPath: profiles.appending(path: "Good.icc").path)
        #expect(goodAttributes[.immutable] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: profiles.appending(path: "Black.icc").path))
        #expect(FileManager.default.fileExists(atPath: profiles.appending(path: "readme.txt").path))

        let again = ExistingProfileSecurity.secure(profileDirectory: profiles, quarantineDirectory: quarantine)
        #expect(again.locked.isEmpty && again.quarantined.isEmpty && again.alreadyLocked == 1)
    }
}
