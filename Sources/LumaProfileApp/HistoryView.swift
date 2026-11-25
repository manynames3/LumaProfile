import AppKit
import LumaCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?

    private var selectedSession: CalibrationSession? {
        model.sessions.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            List(model.sessions, selection: $selection) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.display?.name ?? "Unknown display").font(.headline)
                        Spacer()
                        Label(statusTitle(for: session), systemImage: statusSymbol(for: session))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: session))
                    }
                    Text(session.target?.name ?? "No target recorded").font(.subheadline).lineLimit(1)
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4).tag(session.id)
            }
            .scrollContentBackground(.hidden)
            .frame(minWidth: 260, idealWidth: 310)
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No calibration sessions",
                        systemImage: "clock",
                        description: Text("Completed, cancelled, and interrupted runs will appear here.")
                    )
                }
            }

            Group {
                if let session = selectedSession { SessionDetailView(model: model, session: session) }
                else { ContentUnavailableView("Choose a session", systemImage: "sidebar.left") }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("History")
        .safeAreaInset(edge: .top) {
            if !model.sessionLoadIssues.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Luma.caution)
                    Text("\(model.sessionLoadIssues.count) saved run\(model.sessionLoadIssues.count == 1 ? "" : "s") could not be read. The folders were left untouched; reveal local data from Settings before deciding whether to remove them manually.")
                        .font(.caption)
                    Spacer()
                    Button("Show My Data in Finder") { Task { await model.revealLocalData() } }
                }
                .padding(10)
                .background(Luma.caution.opacity(0.12))
            }
        }
        .onAppear { if selection == nil { selection = model.sessions.first?.id } }
        .onChange(of: model.sessions) { _, sessions in
            if !sessions.contains(where: { $0.id == selection }) { selection = sessions.first?.id }
        }
    }

    private func color(for session: CalibrationSession) -> Color {
        if session.activationVerificationAttempt?.status == .failed
            || session.activationVerificationAttempt?.status == .cancelled {
            return Luma.caution
        }
        if let rating = session.verificationAssessment?.rating {
            switch rating {
            case .excellent: return Luma.positive
            case .good: return Luma.info
            case .needsAttention: return Luma.caution
            }
        }
        return switch session.state {
        case .completed: Luma.positive
        case .failed, .interrupted: Luma.critical
        case .cancelled: .secondary
        default: Luma.caution
        }
    }

    private func statusTitle(for session: CalibrationSession) -> String {
        if let attempt = session.activationVerificationAttempt {
            switch attempt.status {
            case .failed: return attempt.restoredBeforeProfile == true ? "Attempt failed · restored" : "Attempt failed"
            case .cancelled: return attempt.restoredBeforeProfile == true ? "Cancelled · restored" : "Cancelled attempt"
            case .inProgress: return "Switching to the new profile…"
            case .verified, .activated: break
            }
        }
        if let rating = session.verificationAssessment?.rating { return rating.rawValue }
        return switch session.state {
        case .completed: "Complete"
        case .failed: "Failed"
        case .interrupted: "Needs fixing"
        case .cancelled: "Cancelled"
        default: "In progress"
        }
    }

    private func statusSymbol(for session: CalibrationSession) -> String {
        if let attempt = session.activationVerificationAttempt {
            switch attempt.status {
            case .failed: return "exclamationmark.triangle.fill"
            case .cancelled: return "arrow.uturn.backward.circle.fill"
            case .inProgress: return "clock.fill"
            case .verified, .activated: break
            }
        }
        if session.verificationAssessment?.rating == .needsAttention {
            return "exclamationmark.triangle.fill"
        }
        return switch session.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "arrow.uturn.backward.circle.fill"
        case .cancelled: "minus.circle.fill"
        default: "clock.fill"
        }
    }
}

private struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    var session: CalibrationSession
    @State private var isConfirmingDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.display?.name ?? "Unknown display").lumaDisplay()
                    Text(session.updatedAt.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { inspectionActions; managementActions }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { inspectionActions }
                            HStack { managementActions }
                        }
                    }
                    .padding(.top, 6)
                }
                LumaCard("Session") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        row("Status", session.state.rawValue.capitalized)
                        row("Meter", session.instrument?.model ?? "—")
                        row("Target", session.target?.name ?? "—")
                        if let planned = session.plannedCharacterizationPatchCount {
                            let actual = session.actualCharacterizationPatchCount ?? planned
                            row("Patches", "\(actual)\(actual == planned ? "" : " (planned \(planned))")")
                        }
                        row("Profile", session.profileModel?.rawValue ?? "Not recorded")
                        row("Correction", session.correction?.name ?? "Meter default")
                        row("Engine", session.environment?.engineVersion ?? "Not recorded")
                        row("macOS", session.environment?.operatingSystem ?? "Not recorded")
                        if let generatedAt = session.profileGenerationCompletedAt {
                            row("Generated", generatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let attempt = session.activationVerificationAttempt {
                            row("New profile", plainStatus(attempt.status))
                            row("Back on old profile", attempt.restoredBeforeProfile.map { $0 ? "Yes" : "No, the new profile is in use" } ?? "Unconfirmed")
                            if let error = attempt.errorMessage { row("Note", error) }
                        }
                    }
                }
                if let report = session.verification {
                    LumaCard("Accuracy Check") {
                        VerificationMetricsView(report: report, assessment: session.verificationAssessment)
                    }
                }
                LumaCard("Artifacts") {
                    VStack(alignment: .leading, spacing: 10) {
                        if session.artifacts.isEmpty { Text("No artifacts recorded.").foregroundStyle(.secondary) }
                        ForEach(session.artifacts) { artifact in
                            HStack {
                                Image(systemName: artifact.isComplete ? "doc.badge.checkmark" : "doc.badge.ellipsis")
                                VStack(alignment: .leading) {
                                    Text(artifact.kind)
                                    Text(artifact.url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                            }
                        }
                    }
                }
                if session.profileBaseline != nil || session.artifacts.contains(where: {
                    $0.isComplete && $0.url.pathExtension.caseInsensitiveCompare("icc") == .orderedSame
                }) {
                    ProfileBeforeAfterView(model: model, session: session)
                }
            }
            .padding(Luma.pagePadding).frame(maxWidth: 760, alignment: .leading)
        }
        .confirmationDialog("Delete this session?", isPresented: $isConfirmingDeletion, titleVisibility: .visible) {
            Button("Delete This Run and Its Files", role: .destructive) {
                Task { await model.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes this run's folder, logs, measurements, and the new profile. It cannot be undone. Runs that may be needed to put a profile back cannot be deleted here.")
        }
    }

    @ViewBuilder
    private var inspectionActions: some View {
        Button("Show Files") { Task { await model.revealSession(session) } }
        Button("Export Report…") { model.exportReport(for: session) }
            .disabled(model.hasActiveOperation)
    }

    @ViewBuilder
    private var managementActions: some View {
        Button("Copy Details") { model.copyDiagnostics(for: session) }
        Button("Delete This Run…", role: .destructive) { isConfirmingDeletion = true }
            .disabled(session.installation != nil || session.state == .interrupted)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}

private func plainStatus(_ status: ActivationVerificationAttemptStatus) -> String {
    switch status {
    case .inProgress: "Switching on…"
    case .verified: "Switched on and checked"
    case .activated: "Switched on, not checked"
    case .failed: "Couldn't be switched on"
    case .cancelled: "Cancelled"
    }
}
