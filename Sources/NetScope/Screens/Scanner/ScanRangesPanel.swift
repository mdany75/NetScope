import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// « Plages à scanner » : une carte par plage (case à cocher, VLAN, progression, compteurs)
/// et la carte « Ajouter une plage ».
struct ScanRangesPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController

    private var checkedRanges: [ScanRangeConfig] { state.ranges.filter(\.isEnabled) }

    private var summary: String {
        // Adresses vraiment sondées : plages cochées moins les plages exclues du site (note 82).
        let parsed = checkedRanges.compactMap { try? $0.parsed() }
        let exclusions = SiteModel.shared.activeExclusions
        let total = exclusions.isEmpty ? parsed.reduce(0) { $0 + $1.count } : exclusions.probeCount(in: parsed)
        let count = checkedRanges.count
        return "\(count) \(count > 1 ? "plages actives" : "plage active") · \(total) adresse\(total > 1 ? "s" : "")"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                // Note 28 : site actif (préréglage des plages, inventaire et résultats du site).
                ScanSiteBar()
                HStack(spacing: 10) {
                    ScanCardTitle(text: "Plages à scanner")
                    Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    ScanExcludedLabel()
                    if scan.isRunning { runningLabel }
                    Spacer(minLength: 8)
                    if let toast = scan.toast, toast.place == .ranges {
                        ScanToastView(toast: toast).frame(maxWidth: 520).fixedSize(horizontal: true, vertical: false)
                    }
                    Button { scan.detectNetwork(state) } label: {
                        Label("Détecter mon réseau", systemImage: "scope")
                    }
                    .buttonStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(state.ranges) { config in
                        ScanRangeCard(config: config, scan: scan)
                    }
                    ScanAddRangeCard()
                }
                ScanPipelineBar(scan: scan)
            }
        }
        .animation(.easeOut(duration: 0.15), value: scan.toast)
    }

    private var runningLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                ScanPulseDot()
                Text("Scan en cours · \(ScanFormat.seconds(scan.duration(at: context.date) ?? 0))\(scan.phase.map { " · \($0.label)" } ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentStrong)
            }
        }
    }
}

/// Étapes du scan pendant qu'il tourne (Ping → Table ARP → Noms et ports → Switchs (SNMP) →
/// Emplacements), puis le bilan de la découverte automatique des switchs.
struct ScanPipelineBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController
    @ObservedObject private var switches = SwitchStore.shared
    @ObservedObject private var prefs = RegPrefs.shared
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        if scan.isRunning, let current = scan.phase {
            phases(current: current)
        } else if !prefs.autoDiscoverSwitches, state.scanProfile != .complet {
            note("Découverte automatique des switchs désactivée (Réglages › Switchs).")
        } else if let shown = state.switchPresentation(switches.autoResult) {
            let result = shown.result
            if shown.isStale {
                // Autre interface, autre sous-réseau ou autre passerelle depuis ce scan : rien n'est présenté comme actuel.
                note("\(prefix(result))bilan des switchs d’un scan précédent sur \(result.network?.label ?? "un autre réseau")\u{00A0}; le réseau a changé depuis. Relancez le scan pour le mettre à jour.")
                    .help(rangesHelp(result))
            } else if result.interrupted {
                note("\(prefix(result))découverte des switchs interrompue\u{00A0}: relancez le scan pour la terminer.")
                    .help(rangesHelp(result))
            } else if result.foundSwitch {
                found(result)
            } else {
                RegNotice(text: missingText(result), tone: .warning) {
                    Button { openSettings(result) } label: { Label("Ouvrir les Réglages", systemImage: "gearshape") }
                        .buttonStyle(.secondary)
                }
                .help(rangesHelp(result))
            }
        }
    }

    /// « Plage 10.182.122.0/24 : » devant chaque message du bilan (vide pour un bilan sans plage) ;
    /// plages nommées par leur texte saisi, « 3 plages » au-delà de deux.
    private func prefix(_ result: SwitchAutoResult) -> String {
        result.ranges.isEmpty ? "" : "\(result.rangesLabel(names: state.rangeNames))\u{00A0}: "
    }

    /// Liste complète des plages du bilan (aide au survol).
    private func rangesHelp(_ result: SwitchAutoResult) -> String {
        result.ranges.isEmpty ? "" : "Plages du bilan\u{00A0}: " + ScanRelevance.rangesList(result.ranges, names: state.rangeNames)
    }

    /// Première lettre en majuscule quand le message n'a pas de préfixe de plage.
    private func sentence(_ result: SwitchAutoResult, _ text: String) -> String {
        let head = prefix(result)
        return head.isEmpty ? text.prefix(1).uppercased() + text.dropFirst() : head + text
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 11))
            Text(text)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func phases(current: ScanPhase) -> some View {
        let list = scan.plannedPhases.isEmpty ? ScanPhase.allCases : scan.plannedPhases
        let position = list.firstIndex(of: current) ?? 0
        return HStack(spacing: 8) {
            ForEach(Array(list.enumerated()), id: \.element) { index, phase in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: 5) {
                    if index < position {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    } else if index == position {
                        ScanPulseDot()
                    } else {
                        Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
                    }
                    Text(phase.label)
                        .font(.system(size: 12, weight: index == position ? .semibold : .regular))
                        .foregroundStyle(index == position ? Theme.accentStrong : (index < position ? Theme.text : Theme.textSecondary))
                }
                .font(.system(size: 11))
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func found(_ result: SwitchAutoResult) -> some View {
        let count = result.switchNames.count
        let names = result.switchNames.prefix(4).joined(separator: ", ") + (count > 4 ? "…" : "")
        // Même place que dans les autres messages : « Plage 10.182.122.0/24 : 2 switchs relevés (…) ».
        let head = result.ranges.isEmpty ? "Switchs\u{00A0}: \(count) relevé\(count > 1 ? "s" : "")"
            : "\(prefix(result))\(count) switch\(count > 1 ? "s" : "") relevé\(count > 1 ? "s" : "")"
        var text = "\(head) (\(names)) · \(result.located) appareil\(result.located > 1 ? "s" : "") localisé\(result.located > 1 ? "s" : "")"
        if result.filledMACs > 0 { text += " · \(result.filledMACs) MAC complétée\(result.filledMACs > 1 ? "s" : "") par l’ARP SNMP" }
        // FortiSwitch gérés relus par la FortiGate à la fin de ce scan (note 24) : ils localisent
        // aussi des appareils, sans passer par SNMP.
        // Note 25 : une FortiGate par site, celles qui couvrent les plages scannées.
        let read = fortigate.sites.filter { !$0.report.switches.isEmpty && $0.report.readAt >= result.date.addingTimeInterval(-600) }
        if fortigate.isEnabled, !read.isEmpty {
            let count = read.reduce(0) { $0 + $1.report.switches.count }
            text += " · FortiGate \(read.map(\.label).joined(separator: ", "))\u{00A0}: \(count) FortiSwitch"
        }
        if !result.failed.isEmpty { text += " · \(result.failed.count) sans relevé" }
        let help = [text, rangesHelp(result)].filter { !$0.isEmpty }.joined(separator: "\n")
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.success)
            // Deux lignes au plus en petite fenêtre plutôt qu'une phrase coupée.
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(help)
            Spacer(minLength: 8)
            Button("Voir les switchs") { state.open(.switchs) }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .fixedSize()
        }
    }

    private func missingText(_ result: SwitchAutoResult) -> String {
        if result.noCommunity {
            return sentence(result, "aucune communauté SNMP à essayer\u{00A0}: la liste de Réglages › Switchs est vide et aucune communauté n’est enregistrée dans les Identifiants.")
        }
        let queried = "\(result.queried) hôte\(result.queried > 1 ? "s" : "") interrogé\(result.queried > 1 ? "s" : "") avec \(result.communitiesTried) communauté\(result.communitiesTried > 1 ? "s" : "")"
        if !result.failed.isEmpty {
            let names = result.failedNames.prefix(3).joined(separator: ", ")
            return sentence(result, "switch interrogé mais relevé impossible (\(names))\u{00A0}: délai dépassé ou accès refusé à la table MAC. Réessayez depuis «\u{00A0}Switchs et ports\u{00A0}».")
        }
        if result.responded > 0 {
            return sentence(result, "\(queried)\u{00A0}: \(result.responded) appareil\(result.responded > 1 ? "s ont" : " a") répondu en SNMP, mais aucun n’est un switch. Si vos switchs sont sur un VLAN de gestion, ajoutez cette plage au scan ou ajoutez le switch à la main.")
        }
        return sentence(result, "\(queried)\u{00A0}: aucune réponse SNMP. Ajoutez la plage de gestion de vos switchs au scan, vérifiez que SNMP v2c en lecture est actif, ou saisissez la bonne communauté.")
    }

    private func openSettings(_ result: SwitchAutoResult) {
        RegNavigation.shared.section = result.noCommunity || result.responded > 0 ? .switchs : .identifiants
        state.open(.reglages)
    }
}

/// Pastille bleue qui pulse pendant le scan.
struct ScanPulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle().fill(Theme.accent).frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Carte d'une plage

struct ScanRangeCard: View {
    @EnvironmentObject private var state: AppState
    let config: ScanRangeConfig
    @ObservedObject var scan: ScanController
    @State private var editing = false

    private var status: ScanController.RangeStatus? { scan.status[config.id] }
    private var range: IPRange? { try? config.parsed() }

    private var isEnabled: Binding<Bool> {
        Binding(get: { state.ranges.first { $0.id == config.id }?.isEnabled ?? false },
                set: { value in
                    if let index = state.ranges.firstIndex(where: { $0.id == config.id }) { state.ranges[index].isEnabled = value }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(config.isEnabled ? "Comprise dans le prochain scan" : "Exclue du prochain scan")
                Button { editing = true } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.text)
                            .font(Theme.mono(13, weight: .semibold))
                            .foregroundStyle(range == nil ? Theme.critical : Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(config.label) · \(config.kindLabel)")
                            .font(Theme.small)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Modifier la plage")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    ScanRangeEditor(config: config) { editing = false }
                }
                Chip(text: config.vlan.map { "VLAN \($0)" } ?? "VLAN ?", mono: true)
                Button { remove() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(scan.isRunning)
                .help("Retirer la plage \(config.text)")
            }
            progressBlock
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(config.isEnabled ? Theme.panel : Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .opacity(config.isEnabled ? 1 : 0.7)
        .contextMenu {
            Button("Modifier…") { editing = true }
            Button("Copier la plage") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(config.text, forType: .string)
            }
            Divider()
            Button("Retirer", role: .destructive) { remove() }.disabled(scan.isRunning)
        }
    }

    @ViewBuilder private var progressBlock: some View {
        // Avant le scan : adresses vraiment sondées (sans les plages exclues du site, note 82).
        let total = status?.progress.total ?? range.map { SiteModel.shared.activeExclusions.probeCount(in: [$0]) } ?? 0
        let done = status?.progress.done ?? 0
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        let complete = status != nil && done >= total
        let finished = status?.finishedAt != nil
        let online = status?.progress.online ?? onlineInRange
        let fresh = newInRange
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ProgressBar(fraction: fraction, color: complete && finished ? Theme.success : Theme.accent)
                    .padding(.top, 10)
                HStack {
                    Text("\(Int((fraction * 100).rounded())) % · \(done)/\(total)")
                    Spacer()
                    Text(timeLabel(at: context.date, complete: complete))
                }
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 6)
            }
        }
        HStack(spacing: 12) {
            Text("\(online) en ligne").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.success)
            Text("\(max(0, done - online)) sans réponse").font(Theme.small).foregroundStyle(Theme.textSecondary)
            Text("\(fresh) nouveaux")
                .font(.system(size: 12, weight: fresh > 0 ? .semibold : .regular))
                .foregroundStyle(fresh > 0 ? Theme.accentStrong : Theme.textSecondary)
        }
        .padding(.top, 6)
    }

    private func timeLabel(at now: Date, complete: Bool) -> String {
        guard let status else { return "en attente" }
        let elapsed = ScanFormat.seconds((status.finishedAt ?? now).timeIntervalSince(status.startedAt))
        if status.finishedAt != nil { return complete ? "\(elapsed) · terminé" : "\(elapsed) · arrêté" }
        return "\(elapsed) · en cours"
    }

    /// Hors scan : appareils en ligne déjà connus dans cette plage.
    private var onlineInRange: Int {
        guard let range else { return 0 }
        return state.devices.filter { $0.isOnline && range.contains($0.ip) }.count
    }

    private var newInRange: Int {
        guard let range else { return 0 }
        return scan.newIDs.compactMap { IPv4Address($0) }.filter { range.contains($0) }.count
    }

    private func remove() {
        state.ranges.removeAll { $0.id == config.id }
    }
}

// MARK: - Modification d'une plage

struct ScanRangeEditor: View {
    @EnvironmentObject private var state: AppState
    let config: ScanRangeConfig
    let close: () -> Void
    @State private var text: String
    @State private var label: String
    @State private var vlan: String
    @State private var error: String?

    init(config: ScanRangeConfig, close: @escaping () -> Void) {
        self.config = config
        self.close = close
        _text = State(initialValue: config.text)
        _label = State(initialValue: config.label)
        _vlan = State(initialValue: config.vlan.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modifier la plage").font(Theme.bodySemibold)
            field("Plage", text: $text, mono: true, prompt: "10.0.0.0/24")
            field("Nom", text: $label, mono: false, prompt: "Bureau")
            field("VLAN", text: $vlan, mono: true, prompt: "facultatif")
            if let error {
                Text(error).font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annuler", action: close).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func field(_ title: String, text: Binding<String>, mono: Bool, prompt: String) -> some View {
        HStack {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 46, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(mono ? Theme.mono(12) : Theme.small)
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try IPRange(parsing: trimmed)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let vlanText = vlan.trimmingCharacters(in: .whitespaces)
        var vlanValue: Int?
        if !vlanText.isEmpty {
            guard let value = Int(vlanText), (1...4094).contains(value) else {
                self.error = "Le VLAN doit être un nombre de 1 à 4094."
                return
            }
            vlanValue = value
        }
        if let index = state.ranges.firstIndex(where: { $0.id == config.id }) {
            state.ranges[index].text = trimmed
            let name = label.trimmingCharacters(in: .whitespaces)
            state.ranges[index].label = name.isEmpty ? "Plage" : name
            state.ranges[index].vlan = vlanValue
        }
        close()
    }
}

// MARK: - Ajouter une plage

struct ScanAddRangeCard: View {
    @EnvironmentObject private var state: AppState

    enum Kind: String, CaseIterable, Identifiable {
        case cidr, span, list, file
        var id: String { rawValue }

        var label: String {
            switch self {
            case .cidr: return "CIDR"
            case .span: return "Début-fin"
            case .list: return "Liste"
            case .file: return "Importer"
            }
        }

        var placeholder: String {
            switch self {
            case .cidr: return "172.16.0.0/22"
            case .span: return "192.168.1.1-192.168.1.254"
            case .list: return "10.0.0.5, 10.0.0.9, 10.0.0.12"
            case .file: return "plages.txt"
            }
        }
    }

    @State private var kind: Kind = .cidr
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ajouter une plage").font(Theme.bodySemibold)
            HStack(spacing: 4) {
                ForEach(Kind.allCases) { item in
                    Button {
                        kind = item
                        error = nil
                        if item == .file { importFile() }
                    } label: {
                        Text(item.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(kind == item ? Theme.accentStrong : Theme.neutralText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(kind == item ? Theme.panel : .clear))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                                .strokeBorder(kind == item ? Theme.accent : Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                TextField("", text: $text, prompt: Text(kind.placeholder).foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(error == nil ? Theme.border : Theme.critical))
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in error = nil }
                Button(action: add) { Label("Ajouter", systemImage: "plus") }
                    .buttonStyle(ScanOutlineButtonStyle(height: 30, font: Theme.bodyMedium))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("CIDR, début-fin, liste séparée par des virgules ou fichier .txt / .csv")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func add() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            _ = try IPRange(parsing: value)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if state.ranges.contains(where: { $0.text == value }) {
            error = "Cette plage est déjà dans la liste."
            return
        }
        state.ranges.append(ScanRangeConfig(text: value, label: "Nouvelle plage"))
        text = ""
        kind = .cidr
    }

    /// Fichier texte ou CSV : une plage par ligne (ou séparées par des virgules) ; les lignes
    /// commençant par # sont ignorées.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Importer des plages"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Lecture impossible de « \(url.lastPathComponent) »."
            return
        }
        let parts = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { $0.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        text = parts.joined(separator: ", ")
    }
}
