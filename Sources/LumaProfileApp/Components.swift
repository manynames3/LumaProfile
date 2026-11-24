import AppKit
import LumaCore
import SwiftUI

struct StatusPill: View {
    var title: String
    var isReady: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isReady ? Luma.positive : Luma.caution)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Luma.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String
    var symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Luma.title)
                Text(subtitle).lumaNote()
            }
        }
    }
}

struct MeasurementCard: View {
    var measurement: LumaCore.Measurement

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Luminance").lumaEyebrow()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", measurement.luminanceCDM2))
                        .font(Luma.heroNumeral)
                    Text("cd/m²").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 190, alignment: .leading)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    LumaMetric(
                        label: "Color temperature",
                        value: measurement.correlatedColorTemperature.map { "\(Int($0)) K" } ?? "—",
                        prominent: true
                    )
                    LumaMetric(
                        label: "Chromaticity xy",
                        value: String(format: "%.4f  %.4f", measurement.chromaticity.x, measurement.chromaticity.y),
                        prominent: true
                    )
                }
                GridRow {
                    LumaMetric(
                        label: "XYZ",
                        value: String(format: "%.2f  %.2f  %.2f", measurement.xyz.x, measurement.xyz.y, measurement.xyz.z)
                    )
                    LumaMetric(
                        label: "Captured",
                        value: measurement.capturedAt.formatted(date: .omitted, time: .standard)
                    )
                }
            }
        }
        .lumaTile(padding: 16)
    }
}

struct VerificationMetricsView: View {
    var report: VerificationReport
    var assessment: VerificationAssessment? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Average ΔE00").lumaEyebrow()
                    Text(String(format: "%.2f", report.metrics.averageDeltaE2000))
                        .font(Luma.heroNumeral)
                        .textSelection(.enabled)
                }
                .frame(minWidth: 150, alignment: .leading)
                assessmentSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Luma.hairline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow {
                    LumaMetric(label: "95th percentile", value: String(format: "%.2f", report.metrics.percentile95DeltaE2000), prominent: true)
                    LumaMetric(label: "Maximum ΔE00", value: String(format: "%.2f", report.metrics.maximumDeltaE2000), prominent: true)
                    LumaMetric(label: "White-point ΔE00", value: String(format: "%.2f", report.metrics.whitePointDeltaE2000), prominent: true)
                }
                GridRow {
                    LumaMetric(label: "Measured white", value: measuredWhiteText)
                    LumaMetric(label: "Luminance", value: luminanceText)
                    LumaMetric(label: "Tone response", value: toneResponseText)
                }
                GridRow {
                    LumaMetric(label: "Black level", value: report.metrics.blackLevelCDM2.map { String(format: "%.4f cd/m²", $0) } ?? "—")
                    LumaMetric(label: "Contrast", value: report.metrics.contrastRatio.map { String(format: "%.0f:1", $0) } ?? "—")
                    LumaMetric(label: "Measured", value: report.measuredAt.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    LumaMetric(label: "Target RMS error", value: report.metrics.toneResponseRMSError.map { String(format: "%.4f", $0) } ?? "—")
                    LumaMetric(label: "Power-fit RMS", value: report.metrics.gammaRMSError.map { String(format: "%.4f", $0) } ?? "—")
                    Color.clear.frame(height: 1)
                }
            }
            if !report.metrics.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Warnings").lumaEyebrow()
                    ForEach(Array(report.metrics.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Luma.caution)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var assessmentSummary: some View {
        if let assessment {
            VStack(alignment: .leading, spacing: 6) {
                Label(assessment.rating.rawValue, systemImage: ratingSymbol(assessment.rating))
                    .font(Luma.title)
                    .foregroundStyle(ratingColor(assessment.rating))
                ForEach(assessment.reasons, id: \.self) { reason in
                    Text(reason).lumaNote()
                }
                Text("Rated with verification criteria v\(assessment.criteriaVersion) on \(assessment.evaluatedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Measured result — no durable overall rating was recorded", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("This is a legacy result. The measurements are shown without applying today's thresholds retroactively.")
                    .lumaNote()
            }
        }
    }

    private var measuredWhiteText: String {
        let xy = String(format: "x %.4f, y %.4f", report.metrics.measuredWhite.x, report.metrics.measuredWhite.y)
        guard let cct = report.metrics.measuredCorrelatedColorTemperature else { return xy }
        return "\(xy) · \(Int(cct)) K"
    }

    private var luminanceText: String {
        let measured = String(format: "%.1f cd/m²", report.metrics.luminanceCDM2)
        guard let target = report.metrics.targetLuminanceCDM2 else { return measured }
        return measured + String(format: " / %.1f target", target)
    }

    private var toneResponseText: String {
        let measured = report.metrics.measuredGamma.map { String(format: "fit γ %.2f", $0) } ?? "fit unavailable"
        guard let target = report.metrics.targetTransferFunction else { return measured }
        let targetDescription: String = switch target {
        case .gamma(let value): String(format: "γ %.2f target", value)
        case .sRGB: "sRGB target"
        case .bt1886: "BT.1886-style target"
        }
        return "\(measured) / \(targetDescription)"
    }

    private func ratingColor(_ rating: VerificationRating) -> Color {
        switch rating {
        case .excellent: Luma.positive
        case .good: Luma.info
        case .needsAttention: Luma.caution
        }
    }

    private func ratingSymbol(_ rating: VerificationRating) -> String {
        switch rating {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

struct ProfileBeforeAfterView: View {
    @ObservedObject var model: AppModel
    var session: CalibrationSession

    @State private var isConfirmingActivation = false
    @State private var isConfirmingActivationOnly = false

    private var generatedProfile: SessionArtifact? {
        session.artifacts.last { artifact in
            artifact.isComplete
                && artifact.url.pathExtension.caseInsensitiveCompare("icc") == .orderedSame
        }
    }

    private var beforeProfileName: String {
        guard let baseline = session.profileBaseline else { return "Not recorded" }
        return baseline.activeProfileURL?.lastPathComponent ?? "macOS default profile"
    }

    private var afterStatus: (title: String, color: Color, symbol: String) {
        if generatedProfile == nil, session.installation == nil {
            return ("No completed candidate", .secondary, "doc.badge.ellipsis")
        }
        if let attempt = session.activationVerificationAttempt {
            switch attempt.status {
            case .failed:
                if attempt.restoredBeforeProfile == true {
                    return ("Activation/verification failed; Before restored", Luma.caution, "arrow.uturn.backward.circle.fill")
                }
                return ("Activation/verification failed; final profile state needs review", Luma.critical, "exclamationmark.triangle.fill")
            case .cancelled:
                if attempt.restoredBeforeProfile == true {
                    return ("Activation/verification cancelled; Before restored", Luma.caution, "arrow.uturn.backward.circle.fill")
                }
                return ("Activation/verification cancelled; final profile state needs review", Luma.caution, "questionmark.circle.fill")
            case .inProgress:
                return ("Activation/verification in progress", Luma.caution, "clock.fill")
            case .verified, .activated:
                break
            }
        }
        guard let installation = session.installation else {
            return ("Generated; not currently activated by this session", .secondary, "circle")
        }
        switch installation.activationStatus {
        case .active:
            return ("Activated by this session", Luma.positive, "checkmark.circle.fill")
        case .activationPending:
            return ("Activation attempted; final state unconfirmed", Luma.caution, "questionmark.circle.fill")
        case .restorationRequired:
            return ("Restoration required; current state unconfirmed", Luma.caution, "exclamationmark.triangle.fill")
        @unknown default:
            return ("Profile state unknown", Luma.caution, "questionmark.circle.fill")
        }
    }

    private var canActivate: Bool {
        session.state == .completed
            && session.profileBaseline != nil
            && session.installation == nil
            && generatedProfile != nil
            && model.hasFinishedInitialRecoveryAudit
            && !model.requiresProtectedCleanupReview
            && !model.hasActiveOperation
            && !model.isRefreshing
            && !model.isRefreshingInstruments
    }

    private var canRestore: Bool {
        (session.installation != nil
            || (session.state == .interrupted && session.profileBaseline != nil))
            && !model.hasActiveOperation
            && !model.isRefreshing
            && !model.isRefreshingInstruments
    }

    var body: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    profileCard(
                        title: "Before",
                        filename: beforeProfileName,
                        status: session.profileBaseline == nil
                            ? "Before profile was not recorded"
                            : "Active when calibration began",
                        symbol: "clock.arrow.circlepath",
                        color: .secondary
                    )
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                    profileCard(
                        title: "After",
                        filename: generatedProfile?.url.lastPathComponent ?? "No completed ICC profile",
                        status: afterStatus.title,
                        symbol: afterStatus.symbol,
                        color: afterStatus.color
                    )
                }

                measuredWhiteComparison

                if model.canCompare(session) || model.comparisonBeforeSessionID == session.id {
                    comparisonToggle
                }

                if session.installation == nil {
                    Text("Your current profile stays active. After is applied only when you choose Activate.")
                        .lumaNote()
                        .help("Generation leaves the ColorSync profile association unchanged. Argyll temporarily adjusts the display VideoLUT while measuring; LumaProfile restores the active profile's calibration when generation ends.")
                }

                if let attempt = session.activationVerificationAttempt,
                   attempt.status == .failed || attempt.status == .cancelled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attempt.errorMessage ?? "The activation and verification attempt did not complete.")
                        if let finishedAt = attempt.finishedAt {
                            Text("Attempt finished \(finishedAt.formatted(date: .abbreviated, time: .shortened)).")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    if canActivate {
                        Button("Activate & Verify") { isConfirmingActivation = true }
                            .buttonStyle(.lumaPrimary)
                            .help("Switches to the new profile, then measures test colours to grade its accuracy. Needs the meter on the screen.")
                        Button("Activate Only") { isConfirmingActivationOnly = true }
                            .help("Switches to the new profile and finishes. No measuring, no grade.")
                    }
                    if canRestore {
                        Button("Restore Before", role: .destructive) {
                            Task { await model.rollback(session) }
                        }
                    }
                    if let generatedProfile {
                        Button("Reveal After") {
                            NSWorkspace.shared.activateFileViewerSelecting([generatedProfile.url])
                        }
                    }
                    if model.isActivationRunning {
                        ProgressView().controlSize(.small)
                        Text("Activating and measuring…").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) {
                            Task { await model.cancelCalibration() }
                        }
                    } else if model.isRestoreRunning {
                        ProgressView().controlSize(.small)
                        Text("Restoring Before…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Label("Profile Before / After", systemImage: "rectangle.split.2x1")
        }
        .alert("Activate and verify the After profile?", isPresented: $isConfirmingActivation) {
            Button("Cancel", role: .cancel) {}
            Button("Activate & Verify") {
                Task { await model.activateAndVerify(session) }
            }
        } message: {
            Text(activationConfirmationMessage)
        }
        .alert("Activate the After profile without checking it?", isPresented: $isConfirmingActivationOnly) {
            Button("Cancel", role: .cancel) {}
            Button("Activate Only") {
                Task { await model.activateAndVerify(session, verify: false) }
            }
        } message: {
            Text("This switches \(session.display?.name ?? "the selected display") to the new profile and stops. Its accuracy is not measured, so no grade is shown. To check it later, choose Restore Before and then Activate & Verify.")
        }
    }

    private var comparisonToggle: some View {
        let showingBefore = model.comparisonBeforeSessionID == session.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Compare on display").lumaEyebrow()
                Spacer()
                if model.isSwitchingComparison {
                    ProgressView().controlSize(.small)
                }
                Picker("Profile shown", selection: Binding(
                    get: { showingBefore ? ProfileComparisonSide.before : .after },
                    set: { side in
                        Task { await model.setComparison(showBefore: side == .before, for: session) }
                    }
                )) {
                    Text("Before").tag(ProfileComparisonSide.before)
                    Text("After").tag(ProfileComparisonSide.after)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .disabled(model.isSwitchingComparison)
            }
            ComparisonReferenceStrip()
            Text(showingBefore
                ? "Showing Before temporarily. After is put back when you switch, start another operation, or quit."
                : "Switch to Before to see the display as it was. This does not undo the activation.")
                .lumaNote()
        }
        .lumaTile(padding: 14)
    }

    private var activationConfirmationMessage: String {
        let displayName = session.display?.name ?? "the selected display"
        let afterName = generatedProfile?.url.lastPathComponent ?? "the generated profile"
        return "This will change \(displayName) from \(beforeProfileName) to \(afterName), then measure verification patches. If activation, verification, or cancellation fails, LumaProfile will attempt to restore Before."
    }

    private var measuredWhiteComparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measured white-patch comparison").lumaEyebrow()
            HStack(spacing: 12) {
                if let before = session.setupMeasurement {
                    whiteMeasurementCard(
                        title: "Before setup reading",
                        luminance: before.luminanceCDM2,
                        chromaticity: before.chromaticity,
                        temperature: before.correlatedColorTemperature,
                        capturedAt: before.capturedAt
                    )
                } else {
                    unavailableMeasurementCard(
                        title: "Before setup reading",
                        detail: "Not captured before calibration"
                    )
                }
                if let report = session.verification {
                    whiteMeasurementCard(
                        title: "After verification",
                        luminance: report.metrics.luminanceCDM2,
                        chromaticity: report.metrics.measuredWhite,
                        temperature: report.metrics.measuredCorrelatedColorTemperature,
                        capturedAt: report.measuredAt
                    )
                } else {
                    unavailableMeasurementCard(
                        title: "After verification",
                        detail: "Available after Activate & Verify"
                    )
                }
            }
            Text("Before is a single setup white reading; After comes from the verification pass. This compares brightness and white point only, not full pre-calibration color accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func whiteMeasurementCard(
        title: String,
        luminance: Double,
        chromaticity: Chromaticity,
        temperature: Double?,
        capturedAt: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).lumaEyebrow()
            Text(String(format: "%.1f cd/m²", luminance)).font(Luma.numeral)
            Text(String(format: "x %.4f · y %.4f", chromaticity.x, chromaticity.y))
                .font(.caption.monospacedDigit())
            if let temperature {
                Text("\(Int(temperature)) K").font(.caption.monospacedDigit())
            }
            Text(capturedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Luma.raised, in: RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous))
    }

    private func unavailableMeasurementCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).lumaEyebrow()
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Luma.raised, in: RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous))
    }

    private func profileCard(
        title: String,
        filename: String,
        status: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).lumaEyebrow()
            Text(filename)
                .font(Luma.mono)
                .lineLimit(2)
                .textSelection(.enabled)
            Label(status, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(Luma.raised, in: RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous))
    }
}

struct EmptyHardwareView: View {
    var title: String
    var description: String
    var symbol: String
    var refresh: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description)
        } actions: {
            Button("Refresh", action: refresh)
        }
    }
}


/// Neutral ramp, grey steps and colour patches to judge a profile switch by eye.
struct ComparisonReferenceStrip: View {
    private static let patches: [Color] = [
        Color(red: 0.80, green: 0.12, blue: 0.12),
        Color(red: 0.90, green: 0.55, blue: 0.12),
        Color(red: 0.92, green: 0.86, blue: 0.20),
        Color(red: 0.20, green: 0.62, blue: 0.24),
        Color(red: 0.14, green: 0.60, blue: 0.72),
        Color(red: 0.16, green: 0.30, blue: 0.78),
        Color(red: 0.52, green: 0.24, blue: 0.70),
        Color(red: 0.86, green: 0.66, blue: 0.56),
        Color(red: 0.55, green: 0.38, blue: 0.30),
        Color(red: 0.36, green: 0.48, blue: 0.62),
    ]

    var body: some View {
        VStack(spacing: 2) {
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                .frame(height: 26)
            HStack(spacing: 0) {
                ForEach(0..<11, id: \.self) { step in
                    Color(white: Double(step) / 10)
                }
            }
            .frame(height: 26)
            HStack(spacing: 0) {
                ForEach(Array(Self.patches.enumerated()), id: \.offset) { _, patch in
                    patch
                }
            }
            .frame(height: 34)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Reference ramp and colour patches for comparing profiles")
    }
}
