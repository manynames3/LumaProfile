import AppKit
import LumaCore
import SwiftUI

struct StatusPill: View {
    var title: String
    var isReady: Bool

    var body: some View {
        Label(title, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isReady ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeasurementCard: View {
    var measurement: LumaCore.Measurement

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
            GridRow {
                metric("Luminance", String(format: "%.1f cd/m²", measurement.luminanceCDM2))
                metric("Color temperature", measurement.correlatedColorTemperature.map { "\(Int($0)) K" } ?? "—")
            }
            GridRow {
                metric("Chromaticity x", String(format: "%.4f", measurement.chromaticity.x))
                metric("Chromaticity y", String(format: "%.4f", measurement.chromaticity.y))
            }
            GridRow {
                metric("XYZ", String(format: "%.2f  %.2f  %.2f", measurement.xyz.x, measurement.xyz.y, measurement.xyz.z))
                metric("Captured", measurement.capturedAt.formatted(date: .omitted, time: .standard))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VerificationMetricsView: View {
    var report: VerificationReport
    var assessment: VerificationAssessment? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            assessmentSummary
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow {
                    resultMetric("Average ΔE00", report.metrics.averageDeltaE2000)
                    resultMetric("95th percentile", report.metrics.percentile95DeltaE2000)
                    resultMetric("Maximum ΔE00", report.metrics.maximumDeltaE2000)
                }
                GridRow {
                    valueMetric("White-point ΔE00", String(format: "%.2f", report.metrics.whitePointDeltaE2000))
                    valueMetric("Measured white", measuredWhiteText)
                    valueMetric("Luminance", luminanceText)
                }
                GridRow {
                    valueMetric("Black level", report.metrics.blackLevelCDM2.map { String(format: "%.4f cd/m²", $0) } ?? "—")
                    valueMetric("Contrast", report.metrics.contrastRatio.map { String(format: "%.0f:1", $0) } ?? "—")
                    valueMetric("Tone response", toneResponseText)
                }
                GridRow {
                    valueMetric("Target RMS error", report.metrics.toneResponseRMSError.map { String(format: "%.4f", $0) } ?? "—")
                    valueMetric("Power-fit RMS", report.metrics.gammaRMSError.map { String(format: "%.4f", $0) } ?? "—")
                    valueMetric("Measured", report.measuredAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if !report.metrics.warnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Warnings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(report.metrics.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var assessmentSummary: some View {
        if let assessment {
            VStack(alignment: .leading, spacing: 7) {
                Label(assessment.rating.rawValue, systemImage: ratingSymbol(assessment.rating))
                    .font(.title2.bold())
                    .foregroundStyle(ratingColor(assessment.rating))
                ForEach(assessment.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Rated with verification criteria v\(assessment.criteriaVersion) on \(assessment.evaluatedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider()
        } else {
            Label("Measured result — no durable overall rating was recorded", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("This is a legacy result. The measurements are shown without applying today's thresholds retroactively.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
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

    private func resultMetric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f", value)).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ratingColor(_ rating: VerificationRating) -> Color {
        switch rating {
        case .excellent: .green
        case .good: .blue
        case .needsAttention: .orange
        }
    }

    private func ratingSymbol(_ rating: VerificationRating) -> String {
        switch rating {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    private func valueMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileBeforeAfterView: View {
    @ObservedObject var model: AppModel
    var session: CalibrationSession

    @State private var isConfirmingActivation = false

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
                    return ("Activation/verification failed; Before restored", .orange, "arrow.uturn.backward.circle.fill")
                }
                return ("Activation/verification failed; final profile state needs review", .red, "exclamationmark.triangle.fill")
            case .cancelled:
                if attempt.restoredBeforeProfile == true {
                    return ("Activation/verification cancelled; Before restored", .orange, "arrow.uturn.backward.circle.fill")
                }
                return ("Activation/verification cancelled; final profile state needs review", .orange, "questionmark.circle.fill")
            case .inProgress:
                return ("Activation/verification in progress", .orange, "clock.fill")
            case .verified:
                break
            }
        }
        guard let installation = session.installation else {
            return ("Generated; not currently activated by this session", .secondary, "circle")
        }
        switch installation.activationStatus {
        case .active:
            return ("Activated by this session", .green, "checkmark.circle.fill")
        case .activationPending:
            return ("Activation attempted; final state unconfirmed", .orange, "questionmark.circle.fill")
        case .restorationRequired:
            return ("Restoration required; current state unconfirmed", .orange, "exclamationmark.triangle.fill")
        @unknown default:
            return ("Profile state unknown", .orange, "questionmark.circle.fill")
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
        GroupBox {
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

                Text("Generation leaves the ColorSync profile association unchanged. Argyll temporarily adjusts the display VideoLUT while measuring; LumaProfile restores the active profile's calibration when generation ends. The After profile is activated only after you confirm it below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                        Button("Activate & Verify After") { isConfirmingActivation = true }
                            .buttonStyle(.borderedProminent)
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
            .padding(8)
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
    }

    private var activationConfirmationMessage: String {
        let displayName = session.display?.name ?? "the selected display"
        let afterName = generatedProfile?.url.lastPathComponent ?? "the generated profile"
        return "This will change \(displayName) from \(beforeProfileName) to \(afterName), then measure verification patches. If activation, verification, or cancellation fails, LumaProfile will attempt to restore Before."
    }

    private var measuredWhiteComparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measured white-patch comparison")
                .font(.headline)
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
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(String(format: "%.1f cd/m²", luminance)).font(.title3.monospacedDigit().weight(.semibold))
            Text(String(format: "x %.4f · y %.4f", chromaticity.x, chromaticity.y))
                .font(.caption.monospacedDigit())
            if let temperature {
                Text("\(Int(temperature)) K").font(.caption.monospacedDigit())
            }
            Text(capturedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private func unavailableMeasurementCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private func profileCard(
        title: String,
        filename: String,
        status: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(filename)
                .font(.body.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
            Label(status, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
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
