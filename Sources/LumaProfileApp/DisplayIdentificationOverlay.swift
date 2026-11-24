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

    func show(
        display: PhysicalDisplay,
        live: LiveAdjustmentState? = nil,
        cancel: @escaping @MainActor () -> Void
    ) throws {
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
            rootView: WhiteMeasurementSurfaceView(live: live) {
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
    var live: LiveAdjustmentState?
    var cancel: () -> Void

    var body: some View {
        ZStack(alignment: live == nil ? .bottomTrailing : .bottom) {
            Color.white
            if let live {
                // Kept at the bottom edge, well away from a centred meter.
                LiveAdjustmentGauge(state: live, done: cancel)
                    .environment(\.colorScheme, .dark)
                    .padding(.bottom, 56)
            } else {
                Button("Cancel Reading", role: .cancel, action: cancel)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .padding(32)
                    .accessibilityHint("Stops the meter reading and closes the white measurement surface.")
            }
        }
        .ignoresSafeArea()
    }
}

/// Latest reading and targets shared between the model and the gauge shown on
/// the white measurement surface.
@MainActor
final class LiveAdjustmentState: ObservableObject {
    @Published private(set) var measurement: LumaCore.Measurement?
    @Published private(set) var readingCount = 0
    @Published private(set) var targetLuminance: Double?
    @Published private(set) var targetTemperature: Double?

    static let luminanceTolerance = 5.0
    static let temperatureTolerance = 250.0

    func begin(measurement: LumaCore.Measurement?, targetLuminance: Double?, targetTemperature: Double?) {
        self.measurement = measurement
        self.targetLuminance = targetLuminance
        self.targetTemperature = targetTemperature
        readingCount = 0
    }

    func record(_ measurement: LumaCore.Measurement) {
        self.measurement = measurement
        readingCount += 1
    }
}

private struct LiveAdjustmentGauge: View {
    @ObservedObject var state: LiveAdjustmentState
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Panel luminance, uncorrected").lumaEyebrow()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.measurement.map { String(format: "%.1f", $0.luminanceCDM2) } ?? "—")
                            .font(Luma.heroNumeral)
                            .contentTransition(.numericText())
                        Text("cd/m²").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(luminanceAdvice.text)
                        .font(Luma.title)
                        .foregroundStyle(luminanceAdvice.color)
                    if let target = state.targetLuminance {
                        Text(String(format: "Target %.0f cd/m²", target))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let target = state.targetLuminance {
                LuminanceTrack(value: state.measurement?.luminanceCDM2, target: target)
            }
            HStack(spacing: 10) {
                Text("White point").lumaEyebrow()
                Text(whitePointText)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(whitePointColor)
                Spacer()
                ProgressView().controlSize(.small)
                Text(state.readingCount == 0 ? "Taking the first reading…" : "Reading \(state.readingCount + 1)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Done", action: done)
                    .buttonStyle(.lumaPrimary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops live readings and keeps the last one.")
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Luma.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: state.readingCount)
    }

    private var luminanceAdvice: (text: String, color: Color) {
        guard let value = state.measurement?.luminanceCDM2 else {
            return ("Waiting for the meter", .secondary)
        }
        guard let target = state.targetLuminance else {
            return ("No brightness target", .secondary)
        }
        let difference = value - target
        if abs(difference) <= LiveAdjustmentState.luminanceTolerance {
            return ("On target", Luma.positive)
        }
        let amount = Int(abs(difference).rounded())
        return (difference > 0 ? "Lower brightness by \(amount)" : "Raise brightness by \(amount)", Luma.caution)
    }

    private var whitePointText: String {
        guard let measured = state.measurement?.correlatedColorTemperature else { return "—" }
        guard let target = state.targetTemperature else { return "\(Int(measured)) K" }
        let difference = measured - target
        if abs(difference) <= LiveAdjustmentState.temperatureTolerance {
            return "\(Int(measured)) K · close to \(Int(target)) K"
        }
        return "\(Int(measured)) K · \(difference > 0 ? "cooler" : "warmer") than \(Int(target)) K"
    }

    private var whitePointColor: Color {
        guard let measured = state.measurement?.correlatedColorTemperature,
              let target = state.targetTemperature else { return .primary }
        return abs(measured - target) <= LiveAdjustmentState.temperatureTolerance ? Luma.positive : Luma.caution
    }
}

/// Target-centred track: the band marks the acceptable range, the dot the
/// latest reading.
private struct LuminanceTrack: View {
    var value: Double?
    var target: Double

    private var lowerBound: Double { target * 0.6 }
    private var upperBound: Double { target * 1.4 }

    private func position(_ luminance: Double, in width: CGFloat) -> CGFloat {
        let clamped = min(max(luminance, lowerBound), upperBound)
        return width * CGFloat((clamped - lowerBound) / (upperBound - lowerBound))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let bandStart = position(target - LiveAdjustmentState.luminanceTolerance, in: width)
            let bandEnd = position(target + LiveAdjustmentState.luminanceTolerance, in: width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 6)
                Capsule()
                    .fill(Luma.positive.opacity(0.55))
                    .frame(width: max(bandEnd - bandStart, 4), height: 6)
                    .offset(x: bandStart)
                if let value {
                    Circle()
                        .fill(Luma.accent)
                        .frame(width: 16, height: 16)
                        .offset(x: position(value, in: width) - 8)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Brightness relative to target")
        .accessibilityValue(value.map { String(format: "%.0f of %.0f candelas per square metre", $0, target) } ?? "No reading yet")
    }
}

/// Floats the "your action is required" prompt above ArgyllCMS's patch window.
/// On a small or single screen that window can cover LumaProfile entirely, and
/// a run that is waiting for Continue then looks like one that is working.
@MainActor
final class RequiredActionPanelPresenter {
    private var panel: NSPanel?

    func show(
        message: String,
        display: PhysicalDisplay?,
        onContinue: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        dismiss()
        let screen = NSScreen.screens.first(where: { screen in
            let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return value?.uint32Value == display?.cgDisplayID
        }) ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let width = min(560, visible.width - 32)
        let host = NSHostingView(
            rootView: RequiredActionPanelView(message: message, onContinue: onContinue, onCancel: onCancel)
                .frame(width: width)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        // Bottom centre: clear of the meter, which hangs at the patch centre.
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + 20,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ArgyllCMS raises its patch window very high; this small prompt has to
        // sit above it. It leaves the rest of the screen, and alerts, visible.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct RequiredActionPanelView: View {
    var message: String
    var onContinue: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(Luma.caution)
            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for you").font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Continue") { onContinue() }
                    .buttonStyle(.lumaPrimary)
                Button("Cancel") { onCancel() }
                    .buttonStyle(.lumaSecondary)
            }
        }
        .padding(16)
        .background(Luma.surface, in: RoundedRectangle(cornerRadius: Luma.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Luma.cardRadius).stroke(Luma.caution.opacity(0.6), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}
