@preconcurrency import ColorSync
import CoreGraphics
import Foundation

/// Detects a display whose loaded colour curve is all zero, which shows as a
/// black screen, and makes ColorSync rebuild it.
///
/// ArgyllCMS 3.5.0 can leave the main display in this state when it loads a
/// calibration for another display. A zeroed curve survives the tool exiting
/// and a plain ColorSync reload; re-associating the display's profile clears it.
public enum DisplayCurveGuard {
    /// A healthy curve ends near 1.0. Even a strong calibration stays far above this.
    static let blackCeiling: Float = 0.05

    static func isBlack(red: [Float], green: [Float], blue: [Float]) -> Bool {
        guard !red.isEmpty, red.count == green.count, red.count == blue.count else { return false }
        return (red.max() ?? 0) < blackCeiling
            && (green.max() ?? 0) < blackCeiling
            && (blue.max() ?? 0) < blackCeiling
    }

    public static func blackDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { display in
            let capacity = max(Int(CGDisplayGammaTableCapacity(display)), 256)
            var red = [CGGammaValue](repeating: 0, count: capacity)
            var green = red
            var blue = red
            var samples: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &samples) == .success,
                  samples > 0 else { return false }
            let used = Int(samples)
            return isBlack(red: Array(red.prefix(used)), green: Array(green.prefix(used)), blue: Array(blue.prefix(used)))
        }
    }

    /// The macOS built-in sRGB profile: always present, read-only, and the
    /// profile that brought blacked-out screens back on real hardware.
    static let systemSRGB = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

    /// Makes every black display usable again and returns the ones repaired.
    ///
    /// For each black display: switch to the display's default profile; if it
    /// is still black, switch to the built-in sRGB profile. Once the screen is
    /// back, its previous profile is tried again and kept only if it loads
    /// without going black. The app and the background guard serialise on a
    /// lock so they never change profiles at the same time.
    @discardableResult
    public static func repairBlackDisplays() -> [CGDirectDisplayID] {
        withRepairLock {
            let black = blackDisplays()
            for display in black {
                let previous = profileURL(for: display)
                var recovered = false
                if setProfile(nil, for: display) {
                    CGDisplayRestoreColorSyncSettings()
                    usleep(400_000)
                    recovered = !blackDisplays().contains(display)
                }
                if !recovered, FileManager.default.fileExists(atPath: systemSRGB.path),
                   setProfile(systemSRGB, for: display) {
                    CGDisplayRestoreColorSyncSettings()
                    usleep(400_000)
                    recovered = !blackDisplays().contains(display)
                }
                guard recovered,
                      let previous,
                      previous.standardizedFileURL != systemSRGB.standardizedFileURL,
                      FileManager.default.fileExists(atPath: previous.path)
                else { continue }
                let safe = profileURL(for: display)
                guard setProfile(previous, for: display) else { continue }
                CGDisplayRestoreColorSyncSettings()
                usleep(400_000)
                if blackDisplays().contains(display) {
                    // The previous profile is what loads as black: keep the safe one.
                    _ = setProfile(safe, for: display)
                    CGDisplayRestoreColorSyncSettings()
                }
            }
            return black
        }
    }

    /// Puts back any display profile that ArgyllCMS's `dispwin` left swapped.
    ///
    /// `dispwin` renames a display's current profile to `<name>.orig`, writes a
    /// "Dispwin Temp" copy in its place, and renames the original back when it
    /// finishes. If it is interrupted, the original is left as `.orig`. This
    /// restores any `.orig` whose rename is more than a minute old and whose
    /// sibling is missing or is a "Dispwin Temp" copy. Returns restored paths.
    @discardableResult
    public static func restoreArgyllLeftovers(
        in roots: [URL] = defaultProfileRoots,
        now: Date = Date()
    ) -> [URL] {
        let fileManager = FileManager.default
        var restored: [URL] = []
        for root in roots {
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let backup as URL in walker where backup.pathExtension == "orig" {
                let original = backup.deletingPathExtension()
                guard ["icc", "icm"].contains(original.pathExtension.lowercased()) else { continue }
                var info = stat()
                guard stat(backup.path, &info) == 0 else { continue }
                let changed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec))
                guard now.timeIntervalSince(changed) > 60 else { continue }
                if fileManager.fileExists(atPath: original.path) {
                    guard let data = try? Data(contentsOf: original),
                          data.range(of: Data("Dispwin Temp".utf8)) != nil else { continue }
                    try? fileManager.setAttributes([.immutable: false], ofItemAtPath: original.path)
                    guard (try? fileManager.removeItem(at: original)) != nil else { continue }
                }
                if (try? fileManager.moveItem(at: backup, to: original)) != nil {
                    restored.append(original)
                }
            }
        }
        if !restored.isEmpty { CGDisplayRestoreColorSyncSettings() }
        return restored
    }

    public static var defaultProfileRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/ColorSync/Profiles", directoryHint: .isDirectory)]
    }

    private static func withRepairLock<T>(_ body: () -> T) -> T {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/LumaProfile", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "display-guard.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private static func profileURL(for display: CGDirectDisplayID) -> URL? {
        guard let profile = ColorSyncProfileCreateWithDisplayID(display)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() as URL?
    }

    private static func setProfile(_ url: URL?, for display: CGDirectDisplayID) -> Bool {
        guard
            let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
            let defaultProfileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
            let userScopeKey = kColorSyncProfileUserScope?.takeUnretainedValue(),
            let hostScopeKey = kColorSyncProfileHostScope?.takeUnretainedValue(),
            let displayClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue()
        else { return false }
        let profileValue: Any = url.map { $0 as CFURL } ?? kCFNull!
        let values: NSDictionary = [
            defaultProfileKey as String: profileValue,
            userScopeKey as String: kCFPreferencesCurrentUser,
            hostScopeKey as String: kCFPreferencesCurrentHost,
        ]
        return ColorSyncDeviceSetCustomProfiles(displayClass, uuid, values)
    }
}
