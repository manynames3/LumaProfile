import AppKit
import LumaCore
import SwiftUI

enum DisplayIdentificationError: LocalizedError {
    case screenUnavailable

    var errorDescription: String? {
        "The selected display is no longer available. Refresh the display list and try again."
    }
}

@MainActor
final class DisplayIdentificationPresenter {
    private var panel: NSPanel?
    private var dismissalTask: Task<Void, Never>?

    func show(display: PhysicalDisplay, engineNumber: Int?) throws {
        dismiss()
        guard let screen = NSScreen.screens.first(where: { screen in
            let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return value?.uint32Value == display.cgDisplayID
        }) else {
            throw DisplayIdentificationError.screenUnavailable
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Keep the identifier above the app but below modal safety alerts.
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: IdentificationOverlayView(
                display: display,
                engineNumber: engineNumber,
                dismiss: { [weak self] in self?.dismiss() }
            )
        )
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

/// Presents the known RGB-white surface used for the optional setup reading.
/// The panel is non-activating so another display can retain LumaProfile's
/// controls, while a small edge control keeps cancellation available when the
/// selected display is the only screen.
@MainActor
final class WhiteMeasurementSurfacePresenter {
    private var panel: NSPanel?
    private(set) var cancelRequested = false

    func show(display: PhysicalDisplay, cancel: @escaping @MainActor () -> Void) throws {
        dismiss()
        cancelRequested = false
        guard let screen = NSScreen.screens.first(where: { screen in
            let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return value?.uint32Value == display.cgDisplayID
        }) else {
            throw DisplayIdentificationError.screenUnavailable
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // A screen-saver-level panel can hide Quit/cancellation alerts on a
        // one-display Mac. Floating remains above the app while allowing modal
        // safety UI to stay visible.
        panel.level = .floating
        panel.backgroundColor = .white
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: WhiteMeasurementSurfaceView {
                self.cancelRequested = true
                cancel()
            }
        )
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct IdentificationOverlayView: View {
    var display: PhysicalDisplay
    var engineNumber: Int?
    var dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            RoundedRectangle(cornerRadius: 34)
                .stroke(.white.opacity(0.9), lineWidth: 8)
                .padding(28)
            VStack(spacing: 18) {
                Text(engineNumber.map(String.init) ?? "✓")
                    .font(.system(size: 180, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(display.name)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                Text("\(display.widthPixels) × \(display.heightPixels) pixels")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.75))
                if let engineNumber {
                    Text("Engine display \(engineNumber)")
                        .font(.title3.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}

private struct WhiteMeasurementSurfaceView: View {
    var cancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.white
            Button("Cancel Reading", role: .cancel, action: cancel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .padding(32)
                .accessibilityHint("Stops the meter reading and closes the white measurement surface.")
        }
        .ignoresSafeArea()
    }
}
