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

    /// Resets each black display to its default profile so the screen is
    /// usable again, then puts its previous profile back if that loads
    /// cleanly. Returns the displays that were black.
    @discardableResult
    public static func repairBlackDisplays() -> [CGDirectDisplayID] {
        let black = blackDisplays()
        for display in black {
            let previous = profileURL(for: display)
            guard setProfile(nil, for: display) else { continue }
            CGDisplayRestoreColorSyncSettings()
            usleep(400_000)
            guard let previous, FileManager.default.fileExists(atPath: previous.path) else { continue }
            guard setProfile(previous, for: display) else { continue }
            usleep(400_000)
            if blackDisplays().contains(display) {
                // The previous profile is what loads as black; stay on the default.
                _ = setProfile(nil, for: display)
                CGDisplayRestoreColorSyncSettings()
            }
        }
        return black
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
