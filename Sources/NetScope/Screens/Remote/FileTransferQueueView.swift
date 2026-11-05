import AppKit
import NetScopeCore
import SwiftUI

// Note 50 : file des transferts (progression, débit, temps restant, reprise après coupure, pause,
// annulation), sous les deux volets du navigateur.

struct FileTransferQueueView: View {
    @ObservedObject var session: FileTransferSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text("TRANSFERTS").font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
                Text(summary).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                Button("Effacer les terminés") { session.clearFinished() }
                    .buttonStyle(.ghost)
                    .font(Theme.small)
                    .disabled(!session.jobs.contains { $0.state == .done || $0.state == .cancelled })
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.panelMuted)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if session.jobs.isEmpty {
                Text("Glissez des fichiers d’un volet à l’autre, ou utilisez les flèches, pour les transférer.")
                    .font(Theme.small).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.jobs) { job in
                            FileTransferJobRow(job: job, session: session)
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        let active = session.jobs.filter(\.state.isActive).count
        let waiting = session.jobs.filter { $0.state == .waiting }.count
        let done = session.jobs.filter { $0.state == .done }.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) en cours · \(FileTransferFormat.rate(session.totalRate))") }
        if waiting > 0 { parts.append("\(waiting) en attente") }
        if done > 0 { parts.append("\(done) terminé\(done > 1 ? "s" : "")") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }
}

/// Une ligne de la file.
struct FileTransferJobRow: View {
    let job: TransferJob
    @ObservedObject var session: FileTransferSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.direction.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(job.direction == .upload ? Theme.accentStrong : Theme.success)
                .frame(width: 22, height: 22)
                .background(Circle().fill(job.direction == .upload ? Theme.accentSoft : Theme.successSoft))
                .help(job.direction == .upload ? "Envoi vers le serveur" : "Réception sur le Mac")
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(destination).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                ProgressBar(fraction: job.fraction ?? 0, color: barColor, height: 5)
                    .opacity(job.fraction == nil && job.state.isActive ? 0.5 : 1)
                Text(job.progressLabel).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(width: 150)
            Text(rateText).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(width: 118, alignment: .trailing)
            stateLabel.frame(width: 120, alignment: .leading)
            actions.frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(failureText ?? "")
    }

    private var destination: String {
        job.direction == .upload ? "vers \(job.remotePath)" : "vers \(job.localURL.deletingLastPathComponent().path)"
    }

    private var barColor: Color {
        switch job.state {
        case .done: return Theme.success
        case .failed: return Theme.critical
        case .retrying, .paused: return Theme.warning
        case .cancelled: return Theme.textTertiary
        default: return Theme.accent
        }
    }

    private var rateText: String {
        switch job.state {
        case .running:
            guard job.bytesPerSecond != nil else { return "…" }
            return FileTransferFormat.rate(job.bytesPerSecond) + " · " + FileTransferFormat.remaining(job.remainingSeconds)
        case .done:
            return job.averageRate.map { "moy. " + FileTransferFormat.rate($0) } ?? ""
        default:
            return ""
        }
    }

    private var failureText: String? {
        if case .failed(let text) = job.state { return text }
        return nil
    }

    @ViewBuilder private var stateLabel: some View {
        switch job.state {
        case .running: Chip(text: "En cours", tone: .accent)
        case .waiting: Chip(text: "En attente", tone: .neutral)
        case .retrying(let attempt): Chip(text: "Reprise · essai \(attempt)", tone: .warning)
        case .paused: Chip(text: "En pause", tone: .warning)
        case .done: Chip(text: "Terminé", tone: .success)
        case .failed: Chip(text: "Échec", tone: .critical)
        case .cancelled: Chip(text: "Annulé", tone: .neutral)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            switch job.state {
            case .running, .retrying, .waiting:
                small("pause.fill", help: "Mettre en pause (reprise là où le transfert s’est arrêté)") { session.pause(job.id) }
                small("xmark", help: "Annuler ce transfert") { session.cancel(job.id) }
            case .paused, .failed, .cancelled:
                small("arrow.clockwise", help: job.transferredBytes > 0 ? "Reprendre là où le transfert s’est arrêté" : "Recommencer") { session.resume(job.id) }
                if job.state != .cancelled {
                    small("xmark", help: "Annuler ce transfert") { session.cancel(job.id) }
                }
            case .done:
                if job.direction == .download, !session.isDemo {
                    small("magnifyingglass", help: "Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.localURL])
                    }
                }
            }
        }
    }

    private func small(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.ghost)
        .help(help)
    }
}
