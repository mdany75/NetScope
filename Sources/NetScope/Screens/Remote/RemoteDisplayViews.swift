import NetScopeCore
import SwiftUI

/// Groupe de segments du croquis : fond gris, segment choisi blanc à bordure accent (26 pt).
struct RemoteSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? Theme.accentStrong : Theme.neutralText)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Theme.panel : .clear))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(on ? Theme.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.neutralSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .fixedSize()
    }
}

/// Section « Affichage » du formulaire (RDP et VNC) : fenêtre ou plein écran, taille, échelle.
struct RemoteDisplayForm: View {
    @Binding var draft: RemoteDraft

    var body: some View {
        let proto = draft.proto
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                label("Affichage")
                HStack(spacing: 12) {
                    RemoteSegmented(options: RemoteDisplayMode.allCases.map { ($0, $0.label) }, selection: $draft.display.mode)
                    if proto == .rdp, draft.display.mode == .fullScreen {
                        Toggle("Tous les écrans", isOn: $draft.display.allMonitors)
                            .toggleStyle(.checkbox).font(Theme.small)
                            .help("La session occupe tous les écrans du Mac (use multimon)")
                    }
                }
            }
            if proto == .rdp, draft.display.mode == .window {
                VStack(alignment: .leading, spacing: 4) {
                    label("Taille de la fenêtre")
                    RemoteSegmented(options: RemoteWindowSize.allCases.map { ($0, $0.label) }, selection: $draft.display.windowSize)
                    if draft.display.windowSize == .custom {
                        HStack(spacing: 6) {
                            RemoteInput(placeholder: "1600", text: $draft.customWidth).frame(width: 80)
                            Text("×").font(Theme.body).foregroundStyle(Theme.textSecondary)
                            RemoteInput(placeholder: "1000", text: $draft.customHeight).frame(width: 80)
                            Text(boundsText).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            if proto == .vnc {
                VStack(alignment: .leading, spacing: 4) {
                    label("Mise à l’échelle")
                    RemoteSegmented(options: RemoteVNCScale.allCases.map { ($0, $0.label) }, selection: $draft.display.vncScale)
                }
            }
            Text(explanation)
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if proto == .vnc, draft.display.mode == .fullScreen {
                SpeedBanner(text: "Session intégrée\u{00A0}: fenêtre plein écran de NetScope. Dans Partage d’écran (menu du bouton « Connecter »), NetScope bascule sa fenêtre en plein écran après l’identification, avec l’autorisation Réglages Système › Confidentialité et sécurité › Accessibilité\u{00A0}; sans elle, la session s’ouvre en fenêtre.",
                            tone: .neutral, systemImage: "info.circle")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var boundsText: String {
        let w = RemoteDisplaySettings.widthRange, h = RemoteDisplaySettings.heightRange
        return "\(w.lowerBound) à \(w.upperBound) × \(h.lowerBound) à \(h.upperBound)"
    }

    private var explanation: String {
        let d = draft.display
        switch draft.proto {
        case .rdp:
            if d.mode == .fullScreen { return "Windows App ouvre la session en plein écran (screen mode id:i:2)." }
            if let size = d.resolvedWindowSize {
                return "Fenêtre de \(RemoteDisplaySettings.sizeLabel(size.width, size.height))\u{00A0}; réduite à l’échelle si la fenêtre est plus petite (smart sizing)."
            }
            return "La résolution de Windows suit la taille de la fenêtre (dynamic resolution)."
        case .vnc:
            // Note 57 : la session intégrée suit aussi ce réglage (« Taille réelle » : 100 %).
            let integrated = d.vncScale == .actual ? "Session intégrée\u{00A0}: 100\u{00A0}%, défilement aux bords. " : "Session intégrée\u{00A0}: ajustée à la fenêtre. "
            return integrated + partageEcranExplanation(d)
        default:
            return ""
        }
    }

    /// Effet du réglage sur Partage d'écran (ouverture par le menu du bouton « Connecter »).
    private func partageEcranExplanation(_ d: RemoteDisplaySettings) -> String {
        switch draft.proto {
        case .vnc:
            switch d.vncScale {
            case .automatic: return "Partage d’écran garde son propre réglage d’échelle."
            case .fit, .actual: return "NetScope règle « \(d.vncScale == .fit ? "Ajuster à l’espace disponible" : "Afficher la taille originale") » de Partage d’écran avant l’ouverture (réglage commun à toutes ses sessions)."
            }
        default:
            return ""
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
    }
}

/// Bouton « Connecter » ; pour RDP et VNC, un menu attenant ouvre en fenêtre ou en plein écran
/// pour cette fois seulement.
struct RemoteConnectButton: View {
    @ObservedObject var model: RemoteModel
    let connection: RemoteConnection
    var large = false
    var tint: Color = Theme.accent
    var isEnabled = true

    private var hasDisplay: Bool { connection.proto == .rdp || connection.proto == .vnc }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                model.connect(connection)
            } label: {
                Label("Connecter", systemImage: "play.fill").labelStyle(RemoteCompactLabelStyle())
                    .font(.system(size: large ? 13 : 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, large ? 14 : 9)
                    .frame(height: large ? 32 : 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasDisplay ? "Ouvrir \(connection.name) (\(connection.display.summary(for: connection.proto)))" : "Ouvrir \(connection.name)")
            if hasDisplay {
                Menu {
                    Section("Pour cette fois") {
                        ForEach(RemoteDisplayMode.allCases) { mode in
                            Button {
                                model.connect(connection, mode: mode)
                            } label: {
                                if mode == connection.display.mode {
                                    Label("Connecter en \(mode == .window ? "fenêtre" : "plein écran")", systemImage: "checkmark")
                                } else {
                                    Text("Connecter en \(mode == .window ? "fenêtre" : "plein écran")")
                                }
                            }
                        }
                    }
                    // Note 57 : VNC s'ouvre dans NetScope ; Partage d'écran reste possible.
                    if connection.proto == .vnc {
                        Divider()
                        Button("Ouvrir dans Partage d’écran") { model.connect(connection, external: true) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.white)
                .foregroundStyle(Color.white)
                .frame(width: large ? 28 : 24, height: large ? 32 : 30)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 16) }
                .help("Connecter en fenêtre ou en plein écran")
            }
            // Note 57 : onglet intégré par défaut ; Terminal garde l'ancien comportement.
            if [.ssh, .telnet, .serie].contains(connection.proto) {
                Menu {
                    Button("Ouvrir dans un onglet de NetScope") { model.connect(connection) }
                    if connection.proto != .serie {
                        Button("Ouvrir dans un nouvel onglet") { model.connect(connection, newTab: true) }
                    }
                    Divider()
                    Button("Ouvrir dans Terminal") { model.connect(connection, inTerminalApp: true) }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.white)
                .foregroundStyle(Color.white)
                .frame(width: large ? 28 : 24, height: large ? 32 : 30)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 16) }
                .help("Ouvrir dans un onglet de NetScope ou dans Terminal")
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tint))
        .fixedSize()
        .speedDisabled(!isEnabled)
    }
}
