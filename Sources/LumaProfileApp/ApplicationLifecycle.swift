import AppKit

@MainActor
final class ApplicationRunGuard {
    static let shared = ApplicationRunGuard()

    weak var model: AppModel?

    private init() {}
}

@MainActor
final class LumaProfileAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = ApplicationRunGuard.shared.model else {
            return .terminateNow
        }
        guard model.shouldGuardTermination else { return .terminateNow }

        if !model.hasFinishedInitialRecoveryAudit {
            let auditAlert = NSAlert()
            auditAlert.alertStyle = .warning
            auditAlert.messageText = "Checking saved recovery state"
            auditAlert.informativeText = "Quit is temporarily unavailable until LumaProfile checks saved sessions for an unfinished Restore Before. Try the check again, then quit when it completes."
            auditAlert.addButton(withTitle: "Retry Recovery Check")
            auditAlert.addButton(withTitle: "Keep LumaProfile Open")
            if auditAlert.runModal() == .alertFirstButtonReturn {
                Task { @MainActor in await model.load() }
            }
            return .terminateCancel
        }

        if model.requiresProtectedCleanupReview && !model.hasActiveOperation {
            let recoveryAlert = NSAlert()
            recoveryAlert.alertStyle = .critical
            recoveryAlert.messageText = "Restore Before before quitting"
            recoveryAlert.informativeText = "LumaProfile could not confirm the display's previous profile state. Quit was cancelled; open the affected session and choose Restore Before, then try again."
            recoveryAlert.addButton(withTitle: "Keep LumaProfile Open")
            recoveryAlert.runModal()
            return .terminateCancel
        }
        guard !terminationInProgress else { return .terminateLater }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.isRestoreRunning
            ? "Finish restoring Before before quitting?"
            : "Stop the active operation before quitting?"
        alert.informativeText = model.isRestoreRunning
            ? "LumaProfile is restoring the previous profile now. It must finish, or Quit will be cancelled so the display is not left in an uncertain state."
            : "LumaProfile needs a moment to stop ArgyllCMS and restore the display's prior calibration state."
        alert.addButton(withTitle: model.isRestoreRunning ? "Wait & Quit" : "Stop Safely & Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        terminationInProgress = true
        Task { @MainActor in
            let stopped = await model.prepareForTermination()
            self.terminationInProgress = false
            if !stopped {
                let failure = NSAlert()
                failure.alertStyle = .critical
                failure.messageText = model.requiresProtectedCleanupReview
                    ? "Restore Before still needs review"
                    : "LumaProfile is still restoring the display"
                failure.informativeText = model.requiresProtectedCleanupReview
                    ? "Quit was cancelled because LumaProfile could not confirm the display's previous profile state. Open the affected session and choose Restore Before, then try again."
                    : "Quit was cancelled because the calibration process did not stop cleanly. Wait for the session to finish cancelling, then try again."
                failure.runModal()
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    @objc
    private func systemWillSleep(_ notification: Notification) {
        guard let model = ApplicationRunGuard.shared.model,
              model.hasActiveOperation else { return }
        Task { @MainActor in
            await model.handleSystemWillSleep()
        }
    }

    @objc
    private func systemDidWake(_ notification: Notification) {
        guard let model = ApplicationRunGuard.shared.model,
              model.hasActiveOperation else { return }
        Task { @MainActor in
            await model.handleSystemDidWake()
        }
    }
}
