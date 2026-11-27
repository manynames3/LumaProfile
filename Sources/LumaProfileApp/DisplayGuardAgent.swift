import CoreGraphics
import Foundation
import LumaCore

/// The black-screen guard that runs in the background, with or without the
/// LumaProfile window open.
///
/// It is the same LumaProfile executable started by launchd with
/// `--display-guard`. It runs at login, keeps running through sleep and wake,
/// and every two seconds checks each display's colour curve. A display that
/// reads black on two checks in a row is repaired (see
/// `DisplayCurveGuard.repairBlackDisplays`). Every 30 seconds it also restores
/// any display profile ArgyllCMS left swapped.
enum DisplayGuardAgent {
    static let argument = "--display-guard"
    static let label = "com.lumaprofile.display-guard"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/LumaProfile/display-guard.log")
    }

    // MARK: Background loop

    static func runForever() -> Never {
        log("Started (pid \(getpid())).")
        var seenLastTime = Set<CGDirectDisplayID>()
        var tick = 0
        while true {
            let black = Set(DisplayCurveGuard.blackDisplays())
            let persistent = black.intersection(seenLastTime)
            seenLastTime = black
            if !persistent.isEmpty {
                let repaired = DisplayCurveGuard.repairBlackDisplays()
                if !repaired.isEmpty {
                    let still = Set(DisplayCurveGuard.blackDisplays()).intersection(repaired)
                    log("Black curve on display(s) \(repaired); repaired \(repaired.count - still.count), still black \(still.count).")
                }
                seenLastTime = []
            }
            if tick % 15 == 0 {
                let restored = DisplayCurveGuard.restoreArgyllLeftovers()
                if !restored.isEmpty {
                    log("Restored profile(s) left swapped by ArgyllCMS: \(restored.map(\.path)).")
                }
            }
            tick &+= 1
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: Installation

    /// Writes the launch agent for this copy of the app and loads it. Safe to
    /// call on every launch: it only rewrites and reloads when something changed.
    static func install() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        // Never install from a build folder or a mounted disk image.
        guard executable.path.contains(".app/Contents/MacOS/"),
              !executable.path.hasPrefix("/Volumes/") else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, argument],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "ThrottleInterval": 30,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let existing = try? Data(contentsOf: plistURL)
        if existing == data, isLoaded { return }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL, options: .atomic)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard status == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap exited with \(status)."])
        }
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var isLoaded: Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
