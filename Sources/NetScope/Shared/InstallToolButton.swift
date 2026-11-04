import AppKit
import NetScopeCore
import SwiftUI

// MARK: - Bouton « Installer » pour les outils externes (note 17)
//
// Là où un outil externe manque (iperf3, telnet, CLI d'Ookla…), afficher
// `InstallToolPanel(tool: .iperf3)` au lieu d'un simple message :
//   - Homebrew présent : « Installer » ouvre Terminal sur un script qui affiche la commande fixe
//     (« brew install <formule> », formule de la liste blanche `InstallableTool`) et attend Entrée ;
//     NetScope vérifie ensuite la présence de l'outil toutes les 3 s (« Vérifier de nouveau » aussi).
//   - Homebrew absent : explication, « Installer Homebrew… » (commande officielle de brew.sh dans
//     Terminal, après Entrée), lien vers brew.sh et vers la page officielle de l'outil.
// Rien n'est installé sans clic, aucune élévation de droits cachée. Ajouter un outil : un cas de
// plus dans `InstallableTool` (NetScopeCore/Tools/ToolInstall.swift), rien d'autre.

/// Présence d'un outil externe et installation en cours ; une instance par outil.
@MainActor
final class ToolInstallMonitor: ObservableObject {
    private static var monitors: [InstallableTool: ToolInstallMonitor] = [:]

    static func shared(_ tool: InstallableTool) -> ToolInstallMonitor {
        if let monitor = monitors[tool] { return monitor }
        let monitor = ToolInstallMonitor(tool: tool)
        monitors[tool] = monitor
        return monitor
    }

    let tool: InstallableTool
    @Published private(set) var presence: ToolPresence
    /// Terminal ouvert : détection automatique en cours.
    @Published private(set) var waiting = false
    /// Dernier message (« Toujours absent », erreur d'ouverture de Terminal).
    @Published var message: String?

    private var polling: Task<Void, Never>?

    private init(tool: InstallableTool) {
        self.tool = tool
        presence = DemoTools.presence(for: tool) ?? ToolInstaller.presence(tool)
    }

    var path: String? { presence.path }

    /// Revérifie la présence de l'outil (et de Homebrew). Renvoie vrai s'il est installé.
    @discardableResult
    func refresh(manual: Bool = false) -> Bool {
        if let demo = DemoTools.presence(for: tool) {
            presence = demo
        } else {
            presence = ToolInstaller.presence(tool)
        }
        if presence.isInstalled {
            stopWaiting()
            message = manual ? "\(tool.displayName) est installé." : nil
        } else if manual {
            message = "\(tool.displayName) est toujours absent."
        }
        return presence.isInstalled
    }

    /// Ouvre Terminal sur la commande « brew install <formule> », qui attend Entrée.
    func install() {
        guard case .missingWithHomebrew(let brew) = presence else { return }
        openTerminal(ToolInstaller.installScript(tool, brewPath: brew), fileName: ToolInstaller.scriptFileName(tool))
    }

    /// Ouvre Terminal sur la commande officielle de brew.sh, qui attend Entrée.
    func installHomebrew() {
        openTerminal(ToolInstaller.homebrewScript(), fileName: ToolInstaller.scriptFileName(nil))
    }

    private func openTerminal(_ script: String, fileName: String) {
        message = nil
        guard !Launcher.isDemo else {
            message = "Démonstration : Terminal ne s’ouvre pas."
            return
        }
        do {
            let url = try RemoteLauncher.writeTemporary(script, fileName: fileName, executable: true)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                message = "Terminal est introuvable."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            startWaiting()
        } catch {
            message = "Ouverture de Terminal impossible : \(error.localizedDescription)"
        }
    }

    /// Détection automatique : toutes les 3 s pendant 30 min au plus.
    private func startWaiting() {
        polling?.cancel()
        waiting = true
        polling = Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.refresh() { return }
            }
            self?.waiting = false
        }
    }

    private func stopWaiting() {
        polling?.cancel()
        polling = nil
        waiting = false
    }
}

/// Bouton « Installer » (Homebrew présent) ou « Installer Homebrew… » (absent).
struct InstallToolButton: View {
    @ObservedObject var monitor: ToolInstallMonitor

    init(tool: InstallableTool) {
        monitor = ToolInstallMonitor.shared(tool)
    }

    var body: some View {
        switch monitor.presence {
        case .installed:
            EmptyView()
        case .missingWithHomebrew:
            Button {
                monitor.install()
            } label: {
                Label("Installer", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primary)
            .controlSize(.small)
            .help("Ouvre Terminal avec « \(monitor.tool.displayCommand) » ; rien ne se lance avant Entrée")
        case .missingWithoutHomebrew:
            Button {
                monitor.installHomebrew()
            } label: {
                Label("Installer Homebrew…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primary)
            .controlSize(.small)
            .help("Ouvre Terminal avec la commande officielle de brew.sh ; rien ne se lance avant Entrée")
        }
    }
}

/// Encadré « outil manquant » : explication, commande visible, Installer, Vérifier de nouveau,
/// liens officiels. Rien n'est affiché quand l'outil est présent.
struct InstallToolPanel: View {
    @ObservedObject var monitor: ToolInstallMonitor
    /// Phrase ajoutée après l'explication (« NetScope utilisera nc en attendant. »).
    var note: String?

    init(tool: InstallableTool, note: String? = nil) {
        monitor = ToolInstallMonitor.shared(tool)
        self.note = note
    }

    var body: some View {
        if !monitor.presence.isInstalled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(monitor.tool.displayName) n’est pas installé")
                            .font(Theme.bodySemibold)
                            .foregroundStyle(Theme.text)
                        Text(explanation)
                            .font(Theme.small)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if case .missingWithHomebrew = monitor.presence {
                    commandLine(monitor.tool.displayCommand)
                }
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    InstallToolButton(tool: monitor.tool)
                    Button {
                        monitor.refresh(manual: true)
                    } label: {
                        Label("Vérifier de nouveau", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    if case .missingWithoutHomebrew = monitor.presence {
                        Link(destination: Homebrew.siteURL) {
                            Label("brew.sh", systemImage: "arrow.up.right.square")
                        }
                        .font(Theme.small)
                        .padding(.top, 4)
                    }
                    Link(destination: monitor.tool.officialURL) {
                        Label(monitor.tool.officialLabel, systemImage: "arrow.up.right.square")
                    }
                    .font(Theme.small)
                    .padding(.top, 4)
                }
                if monitor.waiting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Terminal est ouvert : appuyez sur Entrée pour lancer l’installation. NetScope détectera l’outil de lui-même.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let message = monitor.message {
                    Text(message).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.warning.opacity(0.35)))
        }
    }

    private var explanation: String {
        let purpose = monitor.tool.purpose.prefix(1).uppercased() + monitor.tool.purpose.dropFirst()
        var text: String
        switch monitor.presence {
        case .installed:
            text = ""
        case .missingWithHomebrew:
            text = "\(purpose). « Installer » ouvre Terminal avec la commande ci-dessous ; rien ne se lance avant que vous appuyiez sur Entrée."
        case .missingWithoutHomebrew:
            text = "\(purpose). Homebrew, le gestionnaire de paquets du Mac, est absent : installez-le d’abord (commande officielle de brew.sh, dans Terminal, après Entrée), ou téléchargez l’outil sur sa page officielle."
        }
        if let note { text += " " + note }
        return text
    }

    private func commandLine(_ command: String) -> some View {
        HStack(spacing: 0) {
            Text("% ").foregroundStyle(Theme.consolePrompt)
            Text(command).foregroundStyle(Theme.consoleText)
        }
        .font(Theme.mono(12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
        .textSelection(.enabled)
    }
}

/// Commande à copier (« iperf3 -s ») : bloc console et bouton Copier.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("% ").foregroundStyle(Theme.consolePrompt)
                Text(command).foregroundStyle(Theme.consoleText)
                Spacer(minLength: 0)
            }
            .font(Theme.mono(12))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
            .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .help("Copier « \(command) »")
        }
    }
}
