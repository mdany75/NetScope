import NetScopeCore
import SwiftUI

/// Réglages › Mises à jour (croquis, section « Mises à jour ») : version installée, canal,
/// fréquence, fiche de la nouvelle version, téléchargement, installation, historique, jeton.
struct RegUpdatesSection: View {
    @ObservedObject private var updates = UpdController.shared
    @State private var tokenText = ""

    private var phase: UpdPhase { updates.phase }

    var body: some View {
        RegPanel(title: "Mises à jour",
                 subtitle: "Versions publiées dans les Releases GitHub du projet, vérifiées avant installation.",
                 accessory: {
                     Button {
                         Task { await updates.check(userInitiated: true) }
                     } label: {
                         HStack(spacing: 6) {
                             if phase == .checking {
                                 Circle().fill(Theme.accent).frame(width: 8, height: 8)
                             } else {
                                 Image(systemName: "arrow.clockwise")
                             }
                             Text(phase == .checking ? "Vérification…" : "Rechercher maintenant")
                         }
                     }
                     .buttonStyle(.secondary)
                     .disabled(updates.isBusy)
                 }, content: {
                     tiles
                     settings.padding(.top, 16)
                     VStack(spacing: 0) {
                         RegToggleRow(title: "Vérifier automatiquement",
                                      detail: "Interroge les Releases GitHub selon la fréquence choisie.",
                                      isOn: $updates.prefs.automaticCheck)
                         RegToggleRow(title: "Télécharger et installer automatiquement",
                                      detail: "Télécharge et vérifie en arrière-plan ; le relancement reste à votre initiative.",
                                      isOn: $updates.prefs.automaticInstall)
                     }
                     .padding(.top, 12)
                     if let hold = updates.prefs.rollbackHold {
                         RegNotice(text: "Mise à jour automatique suspendue depuis le retour à la \(hold.version) (le \(RegFormat.day(hold.date)))\u{00A0}: NetScope ne propose ni n’installe plus de version d’elle-même.",
                                   tone: .warning) {
                             Button("Réactiver") { updates.resumeAutomaticUpdates() }.buttonStyle(RegSmallButtonStyle())
                         }
                         .padding(.top, 12)
                     }
                     if let notice = statusNotice {
                         RegNotice(text: notice.text, tone: notice.tone) {
                             if phase == .ignored || (phase == .upToDate && updates.prefs.skippedVersion != nil) {
                                 Button("Ne plus ignorer") { updates.unskip() }.buttonStyle(RegSmallButtonStyle())
                             }
                         }
                         .padding(.top, 12)
                     }
                     if showCard, let release = updates.release {
                         releaseCard(release).padding(.top, 14)
                     }
                     RegUpdatesHistory(updates: updates).padding(.top, 16)
                     tokenBox.padding(.top, 14)
                 })
    }

    // MARK: Tuiles

    private var tiles: some View {
        RegTileRow {
            RegTile(title: "Version installée") {
                (Text("NetScope \(UpdController.currentVersionText) ")
                 + Text("(build \(RegEnvironment.build))").font(Theme.mono(12)).foregroundColor(Theme.textSecondary))
            }
            RegTile("Système requis", "macOS 14 ou ultérieur")
            RegTile(title: "Source · Releases GitHub") {
                Text("mdany75/NetScope").font(Theme.mono(12, weight: .semibold)).foregroundColor(Theme.accent)
            }
            RegTile("Dernière vérification", updates.prefs.lastCheck.map(RegFormat.moment) ?? "Jamais")
        }
    }

    // MARK: Canal et fréquence

    private var settings: some View {
        // Canal et fréquence côte à côte ; l'un sous l'autre en petite fenêtre.
        RegColumns(minColumnWidth: 250, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                RegLabel("Canal")
                RegSegmented(selection: $updates.prefs.channel, options: [
                    .init(value: UpdChannel.stable, label: "Stable"),
                    .init(value: UpdChannel.beta, label: "Bêta (préversions GitHub)"),
                ])
                Text(updates.prefs.channel == .beta
                     ? "Inclut les préversions marquées « Pre-release » sur GitHub : nouveautés plus tôt, stabilité moindre."
                     : "Seulement les versions finales publiées dans les Releases GitHub.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                RegLabel("Fréquence de vérification")
                Picker("", selection: $updates.prefs.frequency) {
                    ForEach(UpdFrequency.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(!updates.prefs.automaticCheck)
                Text(updates.prefs.automaticCheck ? "Vérification automatique activée." : "Vérification automatique désactivée : seulement sur demande.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Messages

    private var versionLabel: String { updates.release?.version?.description ?? "?" }

    private var statusNotice: (text: String, tone: Tone)? {
        let channel = updates.prefs.channel == .beta ? "Bêta" : "Stable"
        switch phase {
        case .idle:
            return ("Cliquez sur « Rechercher maintenant » pour interroger github.com/mdany75/NetScope/releases.", .neutral)
        case .checking:
            return ("Vérification en cours auprès de github.com/mdany75/NetScope/releases…", .accent)
        case .upToDate:
            if let latest = updates.latestKnown?.version, latest > UpdController.currentVersion {
                return ("NetScope \(UpdController.currentVersionText) est à jour : la version \(latest) ne contient pas encore d’image disque.", .success)
            }
            return ("NetScope \(UpdController.currentVersionText) est à jour sur le canal \(channel).", .success)
        case .later:
            return ("Rappel au prochain démarrage de NetScope. La version \(versionLabel) reste disponible.", .neutral)
        case .ignored:
            return ("NetScope \(versionLabel) est ignorée : aucune alerte pour cette version. Une version ultérieure sera signalée normalement.", .warning)
        case .installing:
            return ("Installation de NetScope \(versionLabel) : l’application va se fermer puis redémarrer.", .success)
        case .failed(let message):
            return (message, .critical)
        case .available, .downloading, .verifying, .ready:
            if let blocker = updates.installBlocker { return (blocker, .warning) }
            return nil
        }
    }

    private var showCard: Bool {
        switch phase {
        case .available, .downloading, .verifying, .ready, .installing: return true
        case .failed: return updates.release != nil
        default: return false
        }
    }

    // MARK: Fiche de la nouvelle version

    private func releaseCard(_ release: UpdRelease) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft)
                    Image(systemName: "arrow.down.circle").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updates.reinstallTarget == nil ? "Nouvelle version disponible : NetScope \(versionLabel)"
                                                        : "Réinstallation : NetScope \(versionLabel)").font(Theme.bodySemibold)
                    Text(cardSubtitle(release)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                RegPill(text: "\(UpdController.currentVersionText) → \(versionLabel)", tone: .accent)
            }

            // Notes et vérifications côte à côte ; l'une sous l'autre en petite fenêtre.
            RegColumns(minColumnWidth: 300, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    RegLabel("Notes de version")
                    let lines = release.noteLines
                    if lines.isEmpty {
                        Text("Aucune note publiée.").font(Theme.body).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(Theme.textSecondary)
                            Text(line).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Voir la version sur GitHub") { updates.openReleasePage() }
                        .buttonStyle(.ghost)
                        .padding(.leading, -8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    RegLabel("Vérifications").padding(.bottom, 6)
                    ForEach(displayedChecks, id: \.label) { check in
                        HStack(spacing: 8) {
                            Text(check.label).font(Theme.small).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            RegPill(text: check.state, tone: check.tone).fixedSize()
                        }
                        .help(check.detail)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .downloading(let received, let expected) = phase {
                progress(received: received, expected: expected, title: "Téléchargement en cours…")
            } else if phase == .verifying {
                progress(received: 1, expected: 1, title: "Vérification de la signature…")
            } else if phase == .ready {
                progress(received: 1, expected: 1, title: "Téléchargement terminé, signature vérifiée")
            }

            HStack(spacing: 8) {
                switch phase {
                case .downloading:
                    Button("Annuler le téléchargement") { updates.cancelDownload() }.buttonStyle(.secondary)
                case .verifying, .installing:
                    EmptyView()
                case .ready:
                    Button {
                        updates.installAndRelaunch()
                    } label: { Label("Installer et relancer", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.primary)
                        .disabled(updates.installBlocker != nil)
                default:
                    Button {
                        updates.download()
                    } label: { Label("Télécharger", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.primary)
                        .disabled(release.diskImage == nil)
                }
                Button("Plus tard") { updates.later() }.buttonStyle(.secondary)
                Button("Ignorer cette version") { updates.skip() }.buttonStyle(.secondary)
                Spacer()
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.accent))
    }

    private func cardSubtitle(_ release: UpdRelease) -> String {
        var parts: [String] = []
        if let date = release.publishedAt { parts.append("Publiée le \(RegFormat.day(date))") }
        if let asset = release.diskImage { parts.append(RegFormat.megabytes(asset.size)) }
        parts.append(release.isPrerelease ? "préversion, canal Bêta" : "canal \(updates.prefs.channel == .beta ? "Bêta" : "Stable")")
        return parts.joined(separator: " · ")
    }

    private struct DisplayedCheck {
        let label: String
        let state: String
        let tone: Tone
        let detail: String
    }

    /// Vérifications : prévues avant le téléchargement, puis résultats réels.
    private var displayedChecks: [DisplayedCheck] {
        if !updates.checks.isEmpty {
            return updates.checks.map {
                DisplayedCheck(label: $0.label, state: $0.passed ? "Vérifiée" : "Refusée",
                               tone: $0.passed ? .success : .critical, detail: $0.detail)
            }
        }
        let pending = phase == .verifying ? "En cours" : "Après téléchargement"
        return [
            DisplayedCheck(label: "Signature Developer ID (équipe \(UpdSignature.expectedTeamID))", state: pending, tone: .neutral,
                           detail: "codesign sur l’image disque et l’application"),
            DisplayedCheck(label: "Notarisation Apple (Gatekeeper)", state: pending, tone: .neutral,
                           detail: "spctl --assess sur l’image disque"),
            DisplayedCheck(label: "Identifiant \(UpdSignature.bundleIdentifier)", state: pending, tone: .neutral,
                           detail: "Même application que celle installée"),
        ]
    }

    private func progress(received: Int64, expected: Int64, title: String) -> some View {
        let fraction = expected > 0 ? Double(received) / Double(expected) : 0
        let percent = Int((fraction * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                if case .downloading = phase {
                    Text("\(percent) % · \(RegFormat.megabytes(received)) sur \(RegFormat.megabytes(expected))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            ProgressBar(fraction: fraction, color: phase == .ready ? Theme.success : Theme.accent)
        }
    }

    // MARK: Jeton GitHub

    private var tokenBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RegLabel("Jeton GitHub (facultatif)")
                if updates.hasToken { RegPill(text: "Enregistré dans le Trousseau", tone: .success) }
            }
            Text("Les mises à jour sont téléchargées en HTTPS depuis les Releases GitHub. Aucun jeton n’est requis pour un dépôt public ; pour un dépôt privé, fournissez un jeton à accès en lecture (« Contents : Read-only »). Il est rangé dans le Trousseau (service com.danymenard.netscope.github).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                RegTextField(placeholder: updates.hasToken ? "•••••••• (enregistré, saisir pour remplacer)" : "github_pat_… ou ghp_…",
                             text: $tokenText, mono: true, secure: true)
                    .frame(maxWidth: 420)
                Button("Enregistrer") {
                    updates.saveToken(tokenText)
                    tokenText = ""
                }
                .buttonStyle(.secondary)
                .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Supprimer") { updates.deleteToken() }
                    .buttonStyle(.secondary)
                    .disabled(!updates.hasToken)
                if let message = updates.tokenMessage {
                    Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}
