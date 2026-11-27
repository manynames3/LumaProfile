import Foundation

/// Checks the profiles LumaProfile has already installed, so profiles made
/// before profile locking existed are protected too.
///
/// A healthy profile is locked (the macOS "Locked" flag), so ArgyllCMS's
/// `dispwin` can no longer rename it and write a temporary copy in its place.
/// A damaged one (an ArgyllCMS "Dispwin Temp" copy, or a calibration curve
/// that is all but zero and would show as a black screen) is moved out of the
/// ColorSync folder into LumaProfile's quarantine folder, so macOS stops
/// offering or loading it. Only LumaProfile's own profile folder is touched.
public enum ExistingProfileSecurity {
    public struct Report: Equatable, Sendable {
        public var locked: [URL] = []
        public var quarantined: [URL] = []
        public var alreadyLocked = 0
    }

    public enum Condition: Equatable, Sendable {
        case healthy
        case argyllTemporaryCopy
        case blackCurve
    }

    public static var profileDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/ColorSync/Profiles/LumaProfile", directoryHint: .isDirectory)
    }

    public static var quarantineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/LumaProfile/Quarantined Profiles", directoryHint: .isDirectory)
    }

    @discardableResult
    public static func secure(
        profileDirectory: URL = profileDirectory,
        quarantineDirectory: URL = quarantineDirectory
    ) -> Report {
        let fileManager = FileManager.default
        var report = Report()
        guard let names = try? fileManager.contentsOfDirectory(atPath: profileDirectory.path) else { return report }
        for name in names.sorted() {
            let url = profileDirectory.appending(path: name)
            guard ["icc", "icm"].contains(url.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: url) else { continue }
            let locked = (try? fileManager.attributesOfItem(atPath: url.path)[.immutable] as? Bool) ?? false
            switch condition(of: data) {
            case .healthy:
                if locked {
                    report.alreadyLocked += 1
                } else if (try? fileManager.setAttributes([.immutable: true], ofItemAtPath: url.path)) != nil {
                    report.locked.append(url)
                }
            case .argyllTemporaryCopy, .blackCurve:
                try? fileManager.setAttributes([.immutable: false], ofItemAtPath: url.path)
                try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
                var destination = quarantineDirectory.appending(path: name)
                var suffix = 2
                while fileManager.fileExists(atPath: destination.path) {
                    destination = quarantineDirectory.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(suffix).\(url.pathExtension)")
                    suffix += 1
                }
                if (try? fileManager.moveItem(at: url, to: destination)) != nil {
                    report.quarantined.append(destination)
                }
            }
        }
        return report
    }

    public static func condition(of data: Data) -> Condition {
        if data.range(of: Data("Dispwin Temp".utf8)) != nil { return .argyllTemporaryCopy }
        if let curveMaximum = calibrationCurveMaximum(in: data), curveMaximum < 0.05 { return .blackCurve }
        return .healthy
    }

    /// The highest value in the profile's vcgt calibration table, or nil when
    /// the profile has no table-form vcgt or it cannot be read.
    static func calibrationCurveMaximum(in data: Data) -> Double? {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        guard let tagCount = u32(128), tagCount < 1_000 else { return nil }
        for index in 0..<tagCount {
            let entry = 132 + 12 * index
            guard entry + 12 <= bytes.count,
                  bytes[entry] == 0x76, bytes[entry + 1] == 0x63, bytes[entry + 2] == 0x67, bytes[entry + 3] == 0x74,
                  let offset = u32(entry + 4),
                  let type = u32(offset + 8), type == 0,
                  let channels = u16(offset + 12),
                  let count = u16(offset + 14),
                  let size = u16(offset + 16),
                  channels > 0, count > 0, size == 1 || size == 2
            else { continue }
            let start = offset + 18
            guard start + channels * count * size <= bytes.count else { return nil }
            var maximum = 0.0
            for position in 0..<(channels * count) {
                let value = size == 2
                    ? Double(u16(start + position * 2) ?? 0) / 65_535
                    : Double(bytes[start + position]) / 255
                maximum = max(maximum, value)
            }
            return maximum
        }
        return nil
    }
}
