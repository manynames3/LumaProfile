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
        if model.isComparingBefore {
            // A comparison left Before showing; put After back before quitting.
            Task { @MainActor in
                await model.restoreAfterIfComparing()
                sender.reply(toApplicationShouldTerminate: !model.shouldGuardTermination)
            }
            return .terminateLater
        }
        guard model.shouldGuardTermination else { return .terminateNow }

        if !model.hasFinishedInitialRecoveryAudit {
            let auditAlert = NSAlert()
            auditAlert.alertStyle = .warning
            auditAlert.messageText = "Checking earlier runs"
            auditAlert.informativeText = "Quit is temporarily unavailable until LumaProfile checks saved sessions for one that didn't finish going back to its old profile. Try the check again, then quit when it completes."
            auditAlert.addButton(withTitle: "Check Again")
            auditAlert.addButton(withTitle: "Keep LumaProfile Open")
            if auditAlert.runModal() == .alertFirstButtonReturn {
                Task { @MainActor in await model.load() }
            }
            return .terminateCancel
        }

        if model.requiresProtectedCleanupReview && !model.hasActiveOperation {
            let recoveryAlert = NSAlert()
            recoveryAlert.alertStyle = .critical
            recoveryAlert.messageText = "Fix this screen's profile before quitting"
            recoveryAlert.informativeText = "LumaProfile isn't sure which profile this screen is using. Quit was cancelled; open that run in History and press Go Back to Old Profile, then try again."
            recoveryAlert.addButton(withTitle: "Keep LumaProfile Open")
            recoveryAlert.runModal()
            return .terminateCancel
        }
        guard !terminationInProgress else { return .terminateLater }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.isRestoreRunning
            ? "Finish going back to the old profile first?"
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
                    ? "This screen's profile still needs fixing"
                    : "LumaProfile is still restoring the display"
                failure.informativeText = model.requiresProtectedCleanupReview
                    ? "Quit was cancelled because LumaProfile isn't sure which profile this screen is using. Open that run in History and press Go Back to Old Profile, then try again."
                    : "Quit was cancelled because the calibration process did not stop cleanly. Wait for it to finish cancelling, then try again."
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
