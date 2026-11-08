import NetScopeCore
import SwiftUI

/// Note 78 : import des hôtes de ~/.ssh/config dans le carnet (fenêtre « Importer »). Le fichier
/// est lu, jamais modifié ; les clés ne sont pas copiées (seul leur chemin est repris). L'hôte de la
/// connexion est l'alias : ssh applique ainsi tout le bloc du fichier (algorithmes, options).
struct SSHConfigImportList: View {
    @ObservedObject var model: RemoteModel
    @State private var config = SSHConfigCache.config

    static let subtitle = "Host, HostName, User, Port, ProxyJump et IdentityFile · lecture seule, clés jamais copiées"

    var body: some View {
        let candidates = SSHConfigImport.candidates(from: config, existing: model.connections)
        VStack(spacing: 0) {
            TableHeader(columns: [
                .init(title: "Hôte"),
                .init(title: "HostName", width: 130),
                .init(title: "Utilisateur", width: 100),
                .init(title: "Port", width: 50),
                .init(title: "Rebond", width: 110),
                .init(title: "Action", width: 130, alignment: .trailing),
            ])
            ScrollView {
                VStack(spacing: 0) {
                    if candidates.isEmpty {
                        EmptyState(systemImage: "doc.text.magnifyingglass", title: "Aucun hôte dans ~/.ssh/config",
                                   message: "Les blocs «\u{00A0}Host nom\u{00A0}» sans joker (*, ?, !) apparaîtront ici.")
                            .frame(height: 180)
                    }
                    ForEach(candidates) { candidate in row(candidate) }
                }
            }
            .frame(height: candidates.isEmpty ? 180 : min(CGFloat(candidates.count) * 44, 400))
            if !notes(candidates).isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notes(candidates), id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            HStack(spacing: 10) {
                let fresh = candidates.filter { !$0.alreadySaved && $0.connection != nil }.count
                Text("\(candidates.count) hôte\(candidates.count > 1 ? "s" : "") · \(fresh) nouveau\(fresh > 1 ? "x" : "")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Button {
                    config = SSHConfigCache.reload()
                } label: {
                    Label("Relire le fichier", systemImage: "arrow.clockwise").labelStyle(RemoteCompactLabelStyle())
                }
                .buttonStyle(.secondary)
                Spacer()
                Button("Ajouter tous les nouveaux") { _ = model.addAllFromSSHConfig(candidates) }
                    .buttonStyle(.secondary)
                    .speedDisabled(fresh == 0)
                Button("Terminé") { model.showImport = false }
                    .buttonStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.panelMuted)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .onAppear { config = SSHConfigCache.reload() }
    }

    /// Remarques du fichier (Match ignoré, Include introuvable), puis celles des hôtes.
    private func notes(_ candidates: [SSHConfigCandidate]) -> [String] {
        var result = config.notes
        for candidate in candidates {
            for remark in candidate.remarks { result.append("\(candidate.alias)\u{00A0}: \(remark)") }
        }
        return Array(result.prefix(6))
    }

    private func row(_ candidate: SSHConfigCandidate) -> some View {
        let resolved = candidate.resolved
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                RemoteProtoIcon(proto: .ssh, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.alias).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let key = candidate.connection?.identityFile, !key.isEmpty {
                        Text("Clé \(key)").font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    } else if let problem = candidate.problem {
                        Text(problem).font(Theme.caption).foregroundStyle(Theme.critical).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            Text(resolved.hostName ?? "—").font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).frame(width: 130, alignment: .leading)
            Text(resolved.user ?? "—").font(Theme.mono(12)).lineLimit(1)
                .padding(.horizontal, 8).frame(width: 100, alignment: .leading)
            Text(String(resolved.port ?? 22)).font(Theme.mono(12))
                .padding(.horizontal, 8).frame(width: 50, alignment: .leading)
            Text(resolved.proxyJump.flatMap { $0.isEmpty ? nil : $0 } ?? (resolved.hasProxyCommand ? "ProxyCommand" : "—"))
                .font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(resolved.proxyJump?.isEmpty == false || resolved.hasProxyCommand ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 8).frame(width: 110, alignment: .leading)
            Group {
                if candidate.alreadySaved {
                    Text("Déjà enregistré").font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else if candidate.connection == nil {
                    Text("Non importable").font(Theme.small).foregroundStyle(Theme.critical)
                        .help(candidate.problem ?? "")
                } else {
                    Button("Ajouter") { model.addFromSSHConfig(candidate) }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .help("Ajouter \(candidate.alias) au dossier «\u{00A0}\(SSHConfigImport.folder)\u{00A0}»")
                }
            }
            .padding(.horizontal, 8).frame(width: 130, alignment: .trailing)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
