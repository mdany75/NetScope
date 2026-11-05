import NetScopeCore
import SwiftUI

/// Écran « Ping continu » (docs/croquis/Ping.dc.html) : cibles en parallèle ; un clic retourne la
/// carte d'une cible en Terminal (croquis C, choisi par Dany), avec dessous le traceroute (MTR)
/// de cette cible et le journal des événements. L'écran s'ouvre vide (aucune cible d'office) ;
/// une fois des cibles ajoutées, le ping continue en arrière-plan. Chaque cible peut être mise
/// en pause seule (bouton de sa carte ou clic droit).
struct PingScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var controller = PingController.shared
    @State private var newTarget = ""
    /// Port du mode TCP, tel que saisi (note 65).
    @State private var portText = "443"
    /// Carte retournée (réponses façon Terminal) ; un second clic la remet à l'endroit.
    @State private var flippedID: PingTarget.ID?
    /// Note 78 : tableau compact (au-delà de 9 cibles, ou imposé).
    @StateObject private var compactTable = PingCompactTable.makeModel()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if let note = modeNote {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 13))
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.small)
                .foregroundStyle(Color(light: 0x1E3A8A, dark: 0x9AAFE9))
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(light: 0xDBEAFE, dark: 0x1B3250)).frame(height: 1) }
            }
            GeometryReader { geometry in
                ScrollView {
                    content(width: geometry.size.width - Theme.contentPadding * 2)
                        .padding(.horizontal, Theme.contentPadding)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .screenToolbar { toolbarActions }
        .onAppear {
            controller.activate(with: state)
            // Captures (--snapshot) : NETSCOPE_PING_TERMINAL=1 retourne la carte choisie,
            // NETSCOPE_PING_TERMINAL=pause celle de la cible en pause.
            if Launcher.isDemo {
                switch ProcessInfo.processInfo.environment["NETSCOPE_PING_TERMINAL"] {
                case "1": flippedID = controller.selectedTarget?.id
                case "pause": flippedID = controller.targets.first(where: \.isPaused)?.id
                default: break
                }
            }
        }
        .onChange(of: state.pingTargets) { _, inputs in controller.sync(with: inputs) }
        // Note 78 : la dernière session (cibles et réglages) est gardée pour être rouverte.
        .onChange(of: controller.sessionSignature) { _, _ in controller.autosave() }
    }

    // MARK: Barre d'outils

    @ViewBuilder private var toolbarActions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                StatusDot(tone: controller.isPaused || controller.targets.isEmpty || isAllPaused ? .neutral : .success)
                Text(controller.isPaused || isAllPaused ? "En pause" : controller.targets.isEmpty ? "Aucune cible" : "En direct")
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.text)
                let info = sessionInfo(now: context.date)
                if !info.isEmpty {
                    Text(info)
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            // Marge avant « Exporter CSV » : le texte d'état ne colle pas au bouton.
            .padding(.trailing, 10)
        }
        PingSessionMenu(controller: controller)
        Menu {
            Button("Mesures en CSV…") { controller.exportCSV() }
                .disabled(controller.totalSent == 0)
            Divider()
            Button("Rapport pour le fournisseur Internet (PDF)…") { controller.exportISPReport() }
                .disabled(!controller.hasLongLog)
            Button("Copier le rapport pour le fournisseur Internet (texte)") { controller.copyISPReportText() }
                .disabled(!controller.hasLongLog)
        } label: {
            Label("Exporter", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .help("Mesures en CSV, ou rapport pour le fournisseur Internet\u{00A0}: perte, latence et gigue par heure, périodes de panne")
    }

    /// Toutes les cibles sont en pause une à une.
    private var isAllPaused: Bool {
        !controller.targets.isEmpty && controller.pausedCount == controller.targets.count
    }

    private func sessionInfo(now: Date) -> String {
        // Sans cible, l'état dit déjà « Aucune cible » : pas de doublon à côté.
        guard !controller.targets.isEmpty else { return "" }
        let elapsed = max(0, Int(now.timeIntervalSince(controller.sessionStart)))
        let clock = String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
        let count = controller.targets.count
        let paused = controller.pausedCount
        let targets = "\(count) \(count > 1 ? "cibles" : "cible")" + (paused > 0 ? " (\(paused) en pause)" : "")
        return "Session \(clock) · \(targets) · \(controller.totalSent) envoyés · \(controller.totalLost) perdus"
    }

    // MARK: Barre de contrôle

    private var controlBar: some View {
        // Une ligne si la fenêtre est assez large, sinon deux (comme le croquis, qui passe à la ligne).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                addField.frame(width: 340)
                settingsRow
                Spacer(minLength: 0)
                runButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    addField.frame(minWidth: 280, maxWidth: 560)
                    Spacer(minLength: 0)
                    runButtons
                }
                HStack(spacing: 14) {
                    settingsGroup
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("", text: $newTarget,
                          prompt: Text(addPrompt).foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit(addTarget)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
            Button(action: addTarget) {
                Label("Ajouter", systemImage: "plus")
            }
            .buttonStyle(.primary)
            .fixedSize()
            .disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty
                      || controller.targets.count >= PingController.maxTargets)
        }
    }

    /// Réglages sur une ligne (fenêtre large).
    private var settingsRow: some View {
        HStack(spacing: 14) {
            intervalGroup
            packetGroup
            modeGroup
            soundToggle
        }
        .fixedSize()
    }

    /// Réglages sous le champ : une ligne si possible, sinon le mode (et son port) passe dessous.
    private var settingsGroup: some View {
        ViewThatFits(in: .horizontal) {
            settingsRow
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    intervalGroup
                    packetGroup
                    soundToggle
                }
                .fixedSize()
                modeGroup.fixedSize()
            }
        }
    }

    private var intervalGroup: some View {
            HStack(spacing: 6) {
                Text("Intervalle").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Menu {
                    ForEach(PingOptions.intervals, id: \.self) { value in
                        Button(PingFormat.duration(value)) { controller.setInterval(value) }
                    }
                } label: {
                    Text(PingFormat.duration(controller.interval)).font(Theme.body)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: Theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
            }
    }

    private var packetGroup: some View {
            HStack(spacing: 6) {
                Text("Paquet").font(Theme.small).foregroundStyle(Theme.textSecondary)
                PingSegmented(options: [.init(value: 56, title: "56 o"),
                                        .init(value: 1472, title: "1472 o · MTU",
                                              help: "1472 octets + 28 d’en-têtes = 1500 octets, bit DF activé")],
                              selection: controller.payloadSize) { controller.setPayloadSize($0) }
            }
    }

    private var modeGroup: some View {
            HStack(spacing: 6) {
                Text("Mode").font(Theme.small).foregroundStyle(Theme.textSecondary)
                // Note 65 : protocole des cibles ajoutées sans préfixe (« hôte:port », tcp:// et
                // http(s):// l'emportent toujours). ARP reste à venir.
                PingSegmented(options: [.init(value: "icmp", title: "ICMP", help: "Écho ICMP (ping classique)"),
                                        .init(value: "tcp", title: "TCP", help: "Temps d’établissement TCP (SYN → SYN/ACK) vers un port\u{00A0}: caméras et serveurs qui bloquent l’ICMP"),
                                        .init(value: "http", title: "HTTP(S)", help: "Requête GET\u{00A0}: temps jusqu’au premier octet de la réponse et code HTTP"),
                                        .init(value: "ARP", title: "ARP", enabled: false, help: "Bientôt : sondage ARP du sous-réseau local")],
                              selection: controller.probeMode.rawValue) { value in
                    if let mode = PingProbeMode(rawValue: value) { controller.probeMode = mode }
                }
                if controller.probeMode == .tcp {
                    Text("Port").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.leading, 4)
                    TextField("", text: $portText, prompt: Text("443"))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                        .frame(width: 58)
                        .help("Port TCP des cibles ajoutées en mode TCP")
                        .onChange(of: portText) { _, text in
                            if let port = UInt16(text.trimmingCharacters(in: .whitespaces)), port > 0 { controller.tcpPort = port }
                        }
                        .onAppear { portText = "\(controller.tcpPort)" }
                }
            }
    }

    private var soundToggle: some View {
            Toggle(isOn: $controller.soundOnLoss) {
                Text("Son à la perte").font(Theme.body)
            }
            .toggleStyle(.checkbox)
    }

    private var runButtons: some View {
        HStack(spacing: 6) {
            if controller.isPaused {
                Button(action: controller.togglePause) { Label("Reprendre", systemImage: "play.fill") }
                    .buttonStyle(.primary)
            } else if isAllPaused {
                // Chaque cible a sa propre pause : la pause globale n'aurait rien à reprendre.
                Button(action: controller.resumeAllTargets) { Label("Tout reprendre", systemImage: "play.fill") }
                    .buttonStyle(.primary)
                    .help("Reprendre toutes les cibles mises en pause une à une")
            } else {
                Button(action: controller.togglePause) { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.secondary)
                    .disabled(controller.targets.isEmpty)
            }
            Button(action: controller.reset) { Label("Réinitialiser", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.secondary)
                .disabled(controller.targets.isEmpty)
        }
        .fixedSize()
    }

    private func addTarget() {
        let text = newTarget.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        controller.addFromField(text)
        newTarget = ""
    }

    /// Texte d'aide du champ selon le mode choisi.
    private var addPrompt: String {
        switch controller.probeMode {
        case .icmp: return "Ajouter une cible (IP, hostname, plage)"
        case .tcp: return "Ajouter une cible TCP (IP ou nom, port \(controller.tcpPort))"
        case .http: return "Ajouter une URL ou un nom (https://…)"
        }
    }

    private var modeNote: String? {
        switch controller.probeMode {
        case .icmp: break
        case .tcp:
            return "Ping TCP\u{00A0}: temps de la poignée de main (SYN → SYN/ACK) vers le port \(controller.tcpPort), connexion aussitôt fermée\u{00A0}; un port fermé (RST) compte comme une perte. «\u{00A0}hôte:port\u{00A0}» ou «\u{00A0}tcp://hôte:port\u{00A0}» marche dans tous les modes."
        case .http:
            return "Ping HTTP(S)\u{00A0}: une requête GET par mesure sur une connexion neuve (DNS, TCP et TLS compris), arrêtée au premier octet de la réponse\u{00A0}; code HTTP affiché, une erreur 5xx compte comme une perte. Les redirections ne sont pas suivies."
        }
        guard controller.payloadSize > 1000 else { return nil }
        if controller.dontFragmentRefused {
            return "Test MTU : le système a refusé le bit DF, les paquets de 1500 octets peuvent être fragmentés ; le résultat n’est pas fiable."
        }
        return "Test MTU : 1472 octets de données + 28 octets d’en-tête IP/ICMP = 1500 octets, bit DF activé. Une perte franche signale un MTU réduit sur le chemin (tunnel, PPPoE)."
    }

    // MARK: Tableau compact (note 78)

    @ViewBuilder private var compactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(controller.layoutChoice == .automatic
                         ? "Tableau compact automatique au-delà de \(PingLayoutChoice.cardLimit) cibles · clic droit sur une ligne pour la pause ou le seuil"
                         : "Tableau compact · clic droit sur une ligne pour la pause ou le seuil")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    StandardColumnsMenu(model: compactTable, compact: true)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                // Petite fenêtre : le tableau défile à gauche et à droite au lieu de couper ses colonnes.
                StandardTableHorizontalScroll(
                    minWidth: compactTable.contentWidth(PingCompactTable.widths),
                    height: StandardTableMetrics.height(rows: controller.targets.count, rowHeight: PingCompactTable.rowHeight, maxRows: 16)) {
                    PingCompactTable(controller: controller, table: compactTable) { id in
                        controller.selectedID = id
                        withAnimation(.easeInOut(duration: 0.2)) { flippedID = id }
                    }
                    .standardTableHeight(rows: controller.targets.count, rowHeight: PingCompactTable.rowHeight, maxRows: 16)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            if let id = flippedID, let target = controller.targets.first(where: { $0.id == id }) {
                PingTerminalCard(target: target, payloadSize: controller.payloadSize,
                                 onFlipBack: { withAnimation(.easeInOut(duration: 0.2)) { flippedID = nil } },
                                 onTogglePause: { controller.togglePause(target.id) },
                                 onRemove: { controller.remove(target.id) })
                    .frame(maxWidth: 520, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Contenu

    @ViewBuilder private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            targetsSection(width: width)
            if let target = controller.selectedTarget {
                if width >= 1000 {
                    HStack(alignment: .top, spacing: 16) {
                        PingMTRPanel(controller: controller, target: target)
                            .frame(width: (width - 16) * 1.6 / 2.6)
                        PingJournalPanel(controller: controller)
                            .frame(width: (width - 16) / 2.6)
                    }
                } else {
                    PingMTRPanel(controller: controller, target: target)
                    PingJournalPanel(controller: controller)
                }
            } else {
                PingJournalPanel(controller: controller)
            }
        }
        .frame(width: max(0, width), alignment: .topLeading)
    }

    @ViewBuilder private func targetsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CIBLES · \(controller.targets.count)")
                    .font(Theme.captionSemibold)
                    .kerning(0.6)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                if !controller.targets.isEmpty {
                    Text((controller.usesTable ? "Double-cliquer sur une ligne pour voir ses réponses" : "Cliquer sur une carte pour voir ses réponses et son traceroute")
                         + " · statistiques sur les \(PingController.cardWindow) dernières mesures (\(PingFormat.duration(Double(PingController.cardWindow) * controller.interval)))")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    PingLayoutPicker(controller: controller)
                }
            }
            if controller.targets.isEmpty {
                Panel {
                    VStack(spacing: 10) {
                        EmptyState(systemImage: "waveform.path.ecg",
                                   title: "Aucune cible",
                                   message: "Ajoutez une adresse, un nom d’hôte ou une plage dans le champ ci-dessus, ou envoyez un appareil depuis le Scanner ou sa fiche.")
                            .frame(height: 150)
                        // Note 78 : la dernière session (cibles et réglages) se rouvre d'un clic.
                        if let last = controller.lastSession {
                            HStack(spacing: 8) {
                                Button { controller.reopenLastSession() } label: {
                                    Label("Rouvrir la dernière session", systemImage: "clock.arrow.circlepath")
                                }
                                .buttonStyle(.primary)
                                Button { controller.openSession() } label: { Label("Ouvrir une session…", systemImage: "folder") }
                                    .buttonStyle(.secondary)
                            }
                            Text("\(last.summary) · enregistrée le \(PingISPReport.stamp(last.savedAt))")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else if controller.usesTable {
                compactSection
            } else {
                let columns = width >= 900 ? 3 : width >= 560 ? 2 : 1
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                          alignment: .leading, spacing: 12) {
                    ForEach(controller.targets) { target in
                        if flippedID == target.id {
                            PingTerminalCard(target: target, payloadSize: controller.payloadSize,
                                             onFlipBack: { withAnimation(.easeInOut(duration: 0.2)) { flippedID = nil } },
                                             onTogglePause: { controller.togglePause(target.id) },
                                             onRemove: { controller.remove(target.id) })
                                .transition(.opacity)
                        } else {
                            PingTargetCard(target: target,
                                           isSelected: target.id == controller.selectedTarget?.id,
                                           onSelect: {
                                               controller.selectedID = target.id
                                               withAnimation(.easeInOut(duration: 0.2)) { flippedID = target.id }
                                           },
                                           onTogglePause: { controller.togglePause(target.id) },
                                           onRemove: { controller.remove(target.id) })
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
    }
}
