import AppKit
import NetScopeCore
import SwiftUI

// Blocs de l'écran Switchs et ports, dans l'ordre du croquis Switch.dc.html.

/// Couleurs propres aux sources de localisation (croquis).
enum SwitchSource: String {
    case lldp = "LLDP", cdp = "CDP", fdb = "FDB", arp = "ARP", uplink = "Uplink", fortigate = "FortiGate"

    var colors: (background: Color, foreground: Color) {
        switch self {
        case .lldp: return (Color(light: 0xDBEAFE, dark: 0x1B3250), Color(light: 0x1E40AF, dark: 0x97ABED))
        case .cdp: return (Color(light: 0xE0E7FF, dark: 0x1B2750), Color(light: 0x3730A3, dark: 0xA5A0E3))
        case .fdb: return (Theme.neutralSoft, Theme.neutralText)
        case .arp: return (Theme.successSoft, Color(light: 0x166534, dark: 0x9AE9B8))
        case .uplink: return (Color(light: 0xE2E8F0, dark: 0x253347), Color(light: 0x0F172A, dark: 0xA5B6DF))
        case .fortigate: return (Color(light: 0xFFEDD5, dark: 0x3B2416), Color(light: 0x9A3412, dark: 0xF6B78C))
        }
    }
}

struct SwitchSourceTag: View {
    let source: SwitchSource

    var body: some View {
        Text(source.rawValue)
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(source.colors.foreground)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(source.colors.background))
            .fixedSize()
    }
}

/// Étiquette de champ : 11 pt, majuscules, gris.
struct SwitchFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Champ de saisie natif de macOS (bordure arrondie, grande taille pour s'aligner sur les boutons).
struct SwitchTextFieldStyle: ViewModifier {
    var mono = true

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .font(mono ? Theme.mono(13) : Theme.body)
    }
}

/// Petit bouton natif pour une valeur à essayer ou à ajouter (exemples, switchs trouvés par le scan).
struct SwitchTokenButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

// MARK: - Sources de localisation et interrogation

struct SwitchSourcesPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        Panel(padding: 14) {
            AdaptiveStack(breakpoint: 1000, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Comment l’appareil est localisé").font(Theme.bodySemibold)
                    SwitchFlowLayout(spacing: 8) {
                        source(.lldp, "voisins annoncés")
                        source(.cdp, "trames reçues par ce Mac · voisins CDP par SNMP\u{00A0}: bientôt")
                        source(.fdb, "table MAC par SNMP v2c · BRIDGE-MIB / Q-BRIDGE-MIB")
                        source(.arp, arpText)
                        if fortigate.isConfigured {
                            source(.fortigate, "FortiSwitch gérés (FortiLink) · API REST de la FortiGate du site, prioritaire sur SNMP")
                        }
                    }
                    Text("Un port d’accès qui apprend la MAC est retenu en priorité\u{00A0}; les ports trunk et uplink (voisin LLDP ou nombreuses MAC) sont ignorés.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            SwitchFieldLabel("Version")
                            // Menu natif : seul SNMP v2c est disponible, v3 est affiché grisé (bientôt).
                            Picker("Version SNMP", selection: Binding(get: { "v2c" }, set: { _ in })) {
                                Text("SNMP v2c").tag("v2c")
                                Text("SNMP v3 (bientôt)").tag("v3").disabled(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.large)
                            .frame(width: 168)
                            .help("SNMP v3 (authPriv) n’est pas encore implémenté dans cette version.")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            SwitchFieldLabel("Communauté (lecture)")
                            SecureField("", text: $store.community, prompt: Text("à saisir").foregroundStyle(Theme.textTertiary))
                                .modifier(SwitchTextFieldStyle())
                                .frame(width: 170)
                                .onSubmit { store.poll(state: state) }
                        }
                        Button { store.poll(state: state) } label: {
                            HStack(spacing: 6) {
                                if store.isPolling || fortigate.isBusy {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
                                }
                                Text(store.isPolling || fortigate.isBusy ? "Interrogation…" : "Interroger les switchs")
                            }
                        }
                        .buttonStyle(.primary)
                        .disabled(!store.canPoll)
                        .opacity(store.canPoll || store.isPolling ? 1 : 0.5)
                        .help(pollHelp)
                    }
                    statusLine
                }
                .fixedSize()
            }
        }
    }

    private var arpText: String {
        if let gateway = state.activeInterface?.gateway { return "passerelle \(gateway) (MAC → IP)" }
        return "scan et tables ARP des switchs (MAC → IP)"
    }

    private var pollHelp: String {
        if store.allHosts.isEmpty, !fortigate.isConfigured { return "Ajoutez d’abord un switch." }
        if !store.canPoll, !store.isPolling { return "Saisissez la communauté SNMP en lecture seule." }
        if fortigate.isConfigured, fortigate.isEnabled {
            return "Interroge chaque switch en SNMP v2c (UDP 161), puis relit les FortiSwitch gérés par les FortiGate qui couvrent les plages cochées (HTTPS, lecture seule)."
        }
        return "Interroge chaque switch en SNMP v2c (UDP 161)."
    }

    @ViewBuilder private var statusLine: some View {
        let snapshots = store.orderedSnapshots
        let fdb = snapshots.reduce(0) { $0 + $1.fdb.count }
        let lldp = snapshots.reduce(0) { $0 + $1.neighbors.count }
        HStack(spacing: 4) {
            if let host = store.pollingHost {
                Text("Interrogation de")
                Text(host).font(Theme.mono(12)).foregroundStyle(Theme.text)
                Text("…")
            } else if fortigate.isBusy {
                Text(fortigate.busySites.count > 1 ? "Lecture des FortiGate" : "Lecture de la FortiGate")
                Text(fortigate.busySites.joined(separator: ", ")).foregroundStyle(Theme.text)
                Text("…")
            } else {
                let count = store.allHosts.count
                let via = store.controllerHosts.count
                Text("Dernier relevé\u{00A0}:")
                Text(store.lastPoll.map(SwitchText.dateTime) ?? "jamais").font(Theme.mono(12)).foregroundStyle(Theme.text)
                Text("· \(count) switch\(count > 1 ? "s" : "")" + (via > 0 ? " (\(via) via FortiGate)" : "") + " · \(fdb) entrées FDB · \(lldp) voisins LLDP")
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func source(_ source: SwitchSource, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(source.rawValue).font(.system(size: 12, weight: .bold))
            Text(text).font(Theme.small)
        }
        .foregroundStyle(source.colors.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(source.colors.background))
        .fixedSize()
    }
}

// MARK: - Cartes des switchs

/// Icône de la carte d'un switch ; avec des ports en erreur, elle passe en rouge avec une pastille
/// du nombre de ports touchés (détail en infobulle).
struct SwitchCardIcon: View {
    let errored: [SNMPInterface]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(errored.isEmpty ? Theme.neutralSoft : Theme.criticalSoft)
            Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 15))
                .foregroundStyle(errored.isEmpty ? Theme.text : Theme.critical)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .topTrailing) {
            if !errored.isEmpty {
                Text("\(errored.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Theme.critical))
                    .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: 1.5))
                    .offset(x: 6, y: -6)
            }
        }
        .help(helpText)
        .accessibilityLabel(errored.isEmpty ? "Switch" : "Switch, \(errored.count) port\(errored.count > 1 ? "s" : "") en erreur")
    }

    private var helpText: String {
        guard !errored.isEmpty else { return "" }
        let count = errored.count
        let list = errored.prefix(6).map { "\($0.name) (\(SwitchText.grouped($0.inErrors ?? 0)))" }.joined(separator: ", ")
        let more = count > 6 ? ", et \(count - 6) autre\(count - 6 > 1 ? "s" : "")" : ""
        return "\(count) port\(count > 1 ? "s" : "") en erreur (au moins \(SNMPSwitchSnapshot.portErrorThreshold) erreurs en entrée depuis le démarrage)\u{00A0}: \(list)\(more). Cliquez pour voir la façade."
    }
}

struct SwitchCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let host: String

    var body: some View {
        let snapshot = store.snapshots[host]
        let active = (store.current?.id ?? store.selectedHost) == host
        Button { store.select(host: host) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SwitchCardIcon(errored: snapshot?.erroredPorts ?? [])
                    VStack(alignment: .leading, spacing: 2) {
                        // Petite fenêtre : la puce d'origine disparaît avant que le nom ne se coupe.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                cardName(snapshot)
                                statusChip(snapshot)
                                if store.isController(host) {
                                    // Note 25 : le site de la FortiGate qui a lu ce FortiSwitch.
                                    Chip(text: snapshot?.controllerName.map { "via FortiGate · \($0)" } ?? "via FortiGate", tone: .accent)
                                        .help("FortiSwitch géré par FortiLink\u{00A0}: lu par l’API REST de la FortiGate \(snapshot?.controllerName.map { "du site «\u{00A0}\($0)\u{00A0}»" } ?? ""), jamais interrogé directement (son adresse FortiLink n’est pas joignable depuis ce Mac).")
                                } else if store.isAutoDiscovered(host) {
                                    Chip(text: "Découvert automatiquement", tone: .accent)
                                        .help("Trouvé par la découverte SNMP à la fin du scan\u{00A0}; la communauté qui a répondu est gardée au Trousseau.")
                                } else if let role = snapshot?.system.location {
                                    Chip(text: role, tone: .neutral)
                                }
                            }
                            if store.isController(host) {
                                HStack(spacing: 8) {
                                    cardName(snapshot)
                                    statusChip(snapshot)
                                    Chip(text: "via FortiGate", tone: .accent)
                                        .help(snapshot?.controllerName.map { "FortiSwitch lu par la FortiGate du site «\u{00A0}\($0)\u{00A0}»." } ?? "FortiSwitch lu par la FortiGate.")
                                }
                            }
                            HStack(spacing: 8) {
                                cardName(snapshot)
                                statusChip(snapshot)
                            }
                            // Nom trop long pour la puce sur la même ligne : l'état passe dessous
                            // plutôt que de disparaître (FSW-ENTREPOT en petite fenêtre).
                            VStack(alignment: .leading, spacing: 4) {
                                cardName(snapshot)
                                statusChip(snapshot)
                            }
                        }
                        Group {
                            if let snapshot, store.isController(host) {
                                Text("\(SwitchText.model(snapshot)) · ") + Text(SwitchText.fortiLinkAddress(snapshot)).font(Theme.mono(12))
                                    + Text(" · \(SwitchText.portsSummary(snapshot))")
                            } else if let snapshot {
                                Text("\(SwitchText.model(snapshot)) · ") + Text(host).font(Theme.mono(12)) + Text(" · \(SwitchText.portsSummary(snapshot))")
                            } else {
                                Text(store.errors[host] ?? "Pas encore interrogé · ") + Text(host).font(Theme.mono(12))
                            }
                        }
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        // Modèle, adresse et ports : deux lignes plutôt qu'une coupée.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let snapshot {
                    // Petite carte : les quatre mesures passent sur deux lignes au lieu d'être coupées.
                    let physical = snapshot.physicalPorts
                    let ports = "\(physical.filter(\.isUp).count) / \(physical.count)"
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            metric("Firmware", SwitchText.firmware(snapshot.system.descr), fits: true)
                            metric(snapshot.isViaController ? "Contrôleur" : "Uptime", SwitchText.uptimeOrController(snapshot), fits: true)
                            metric("Marque", snapshot.system.brand ?? "—", mono: false, fits: true)
                            metric("Ports actifs", ports, fits: true)
                        }
                        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow {
                                metric("Firmware", SwitchText.firmware(snapshot.system.descr))
                                metric(snapshot.isViaController ? "Contrôleur" : "Uptime", SwitchText.uptimeOrController(snapshot))
                            }
                            GridRow {
                                metric("Marque", snapshot.system.brand ?? "—", mono: false)
                                metric("Ports actifs", ports)
                            }
                        }
                    }
                    poe(snapshot)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(active ? Theme.accent : Theme.border, lineWidth: active ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if store.isController(host) {
                Button("Réglages du contrôleur FortiGate…") {
                    RegNavigation.shared.section = .switchs
                    state.open(.reglages)
                }
            } else {
                Button("Retirer ce switch", role: .destructive) { store.removeHost(host) }
            }
            // Note 34 : les autres modules pertinents pour ce switch (fiche, Scanner, Inventaire…).
            Divider()
            OpenInMenu(object: .switchUnit(host: host, name: store.snapshots[host]?.displayName ?? host))
        }
    }

    private func cardName(_ snapshot: SNMPSwitchSnapshot?) -> some View {
        Text(snapshot?.displayName ?? host)
            .font(Theme.mono(14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private func statusChip(_ snapshot: SNMPSwitchSnapshot?) -> some View {
        if store.pollingHost == host {
            Chip(text: "Interrogation…", tone: .accent)
        } else if store.errors[host] != nil {
            Chip(text: "Sans réponse", tone: .critical)
        } else if snapshot != nil {
            Chip(text: "En ligne", tone: .success)
        } else {
            Chip(text: "À interroger", tone: .neutral)
        }
    }

    /// Mesure de la carte ; `fits` : le titre et la valeur doivent tenir en entier (sinon la
    /// disposition sur deux lignes est retenue).
    private func metric(_ title: String, _ value: String, mono: Bool = true, fits: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).fixedSize(horizontal: fits, vertical: false)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize(horizontal: fits, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    @ViewBuilder private func poe(_ snapshot: SNMPSwitchSnapshot) -> some View {
        if let budget = snapshot.poeBudgetW, budget > 0 {
            let used = snapshot.poeUsedW ?? 0
            let fraction = Double(used) / Double(budget)
            VStack(spacing: 4) {
                HStack {
                    Text("PoE utilisé / budget")
                    Spacer()
                    Text("\(used)\u{00A0}W / \(budget)\u{00A0}W · \(Int((fraction * 100).rounded()))\u{00A0}%").font(Theme.mono(12)).foregroundStyle(Theme.text)
                }
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                ProgressBar(fraction: fraction, color: fraction > 0.8 ? Theme.warning : Theme.accent)
            }
        } else {
            HStack {
                Text("PoE").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(snapshot.isViaController ? (snapshot.poeDetails?.isEmpty == false ? "sans budget publié par la FortiGate" : "aucun port PoE")
                     : "non annoncé (POWER-ETHERNET-MIB absente)").font(Theme.small).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Appareils du scan qui ressemblent à des switchs, à ajouter d'un clic.
struct SwitchCandidates: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore

    var body: some View {
        let candidates = store.candidates(from: state.devices)
        if !candidates.isEmpty {
            SwitchFlowLayout(spacing: 8) {
                Text("Trouvés par le scan\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(height: 22)
                ForEach(candidates.prefix(6)) { device in
                    Button { store.addHost(device.id) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text(device.id).font(Theme.mono(12))
                            Text(device.displayName).font(Theme.small).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(SwitchTokenButtonStyle())
                    .help(device.snmpKind == .switch ? "Reconnu comme switch en SNMP" : "Fabricant d’équipement réseau")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Façade et recherche

struct SwitchFaceplatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot
    /// Largeur de la zone de la façade : le cadre sombre la remplit jusqu'au bord de la carte.
    @State private var faceplateWidth: CGFloat = 0

    var body: some View {
        let uplinks = snapshot.locatedUplinks
        let ports = snapshot.physicalPorts
        let states = ports.map { SwitchPortState($0, snapshot: snapshot, uplinks: uplinks) }
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Petite fenêtre : les compteurs passent sous le titre au lieu de déborder.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        title(snapshot)
                        Spacer()
                        stats(states)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        title(snapshot)
                        SwitchFlowLayout(spacing: 6) { stats(states) }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    SwitchFaceplate(snapshot: snapshot, selected: store.selectedPort,
                                    found: store.findResult?.host == snapshot.id ? store.findResult?.ifIndex : nil,
                                    minWidth: faceplateWidth,
                                    onOpen: { index in
                                        store.select(host: snapshot.id, port: index)
                                        state.perform(.port(NavPortRef(host: snapshot.id, ifIndex: index)))
                                    }) { index in
                        store.select(host: snapshot.id, port: index)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { faceplateWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in faceplateWidth = width }
                    }
                }
                SwitchLegend()
                Divider().overlay(Theme.border)
                findBlock
            }
        }
    }

    private func title(_ snapshot: SNMPSwitchSnapshot) -> some View {
        (Text("Façade · ").font(.system(size: 14, weight: .semibold))
            + Text(snapshot.displayName).font(Theme.mono(14, weight: .semibold)))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private func stats(_ states: [SwitchPortState]) -> some View {
        // Erreurs : même compte que l'indicateur de la carte (un uplink en erreur compte aussi).
        stat("Actifs", states.filter { $0 != .down && $0 != .disabled }.count, Theme.successSoft, Color(light: 0x14532D, dark: 0x9CE7BA))
        stat("PoE", states.filter { $0 == .poe }.count, Color(light: 0xDBEAFE, dark: 0x1B3250), Color(light: 0x1E40AF, dark: 0x97ABED))
        stat("Trunk", states.filter { $0 == .trunk }.count, Color(light: 0xE2E8F0, dark: 0x253347), Color(light: 0x0F172A, dark: 0xA5B6DF))
        stat("Erreurs", snapshot.erroredPorts.count, Theme.criticalSoft, Theme.critical)
        stat("Inactifs", states.filter { $0 == .down || $0 == .disabled }.count, Theme.neutralSoft, Theme.neutralText)
    }

    private func stat(_ label: String, _ value: Int, _ background: Color, _ foreground: Color) -> some View {

        (Text("\(label) ") + Text("\(value)").font(Theme.mono(12, weight: .bold)))
            .font(Theme.small)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(background))
            .fixedSize()
    }

    private var findBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SwitchFieldLabel("Trouver un appareil")
                    TextField("", text: $store.findQuery,
                              prompt: Text("IP, MAC ou hostname (ex. 10.182.122.111)").foregroundStyle(Theme.textTertiary))
                        .modifier(SwitchTextFieldStyle())
                        .onSubmit { store.find(store.findQuery, devices: state.devices) }
                }
                Button { store.find(store.findQuery, devices: state.devices) } label: {
                    Label("Localiser le port", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.primary)
            }
            SwitchFlowLayout(spacing: 6) {
                Text("Exemples\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(height: 22)

                ForEach(examples, id: \.self) { example in
                    Button { store.find(example, devices: state.devices) } label: {
                        Text(example).font(Theme.mono(12)).lineLimit(1)
                    }
                    .buttonStyle(SwitchTokenButtonStyle())
                    .help("Localiser «\u{00A0}\(example)\u{00A0}»")
                }
            }
            if let result = store.findResult {
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark" : "exclamationmark.circle").font(.system(size: 12, weight: .bold))
                    Text(result.text).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.clearFind() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .help("Effacer le résultat")
                }
                .foregroundStyle(result.ok ? Color(light: 0x14532D, dark: 0x9CE7BA) : Color(light: 0x9A3412, dark: 0xF2AA91))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(result.ok ? Theme.successSoft : Theme.warningSoft))
            }
        }
    }

    /// Quelques appareils connus et localisables, pour essayer la recherche.
    private var examples: [String] {
        let snapshots = store.orderedSnapshots
        let located = state.devices.filter { device in
            guard let mac = device.mac else { return false }
            return SNMPLocator.locate(mac, in: snapshots) != nil
        }
        var result: [String] = []
        if let first = located.first(where: { $0.deviceType == .imprimante }) ?? located.first { result.append(first.id) }
        if let ap = located.first(where: { $0.deviceType == .pointAcces }), let mac = ap.mac { result.append(mac.formatted(.upperColon)) }
        if let named = located.first(where: { $0.deviceType == .iot }), let host = named.hostname?.split(separator: "-").first {
            result.append(String(host))
        }
        if let camera = located.first(where: { $0.deviceType == .camera }) { result.append(camera.id) }
        return Array(result.prefix(4))
    }
}

// MARK: - Détail du port

struct SwitchPortDetail: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let uplinks = snapshot.locatedUplinks
        let portState = SwitchPortState(iface, snapshot: snapshot, uplinks: uplinks)
        let entries = snapshot.entries(on: iface.index)
        let neighbor = snapshot.neighbor(on: iface.index)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SwitchFieldLabel("Port sélectionné · \(snapshot.displayName)")
                HStack(spacing: 8) {
                    Text(iface.name).font(Theme.mono(18, weight: .semibold))
                    Text(portState.label)
                        .font(Theme.captionSemibold)
                        .foregroundStyle(portState.badge.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(portState.badge.background))
                }
                Text(iface.alias.isEmpty ? iface.descr : iface.alias).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            divider

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                field("État admin / opér.", "\(iface.adminUp ? "Activé" : "Désactivé") / \(iface.operStatus.label)", mono: false)
                field("Vitesse", iface.isUp ? SNMPFormat.speed(mbps: iface.speedMbps) : "—")
                field("VLAN", vlanText(uplinks: uplinks))
                field("PoE", SwitchText.poeLine(iface, snapshot: snapshot), mono: false)
                field("Entrée", SNMPFormat.bytes(iface.inOctets))
                field("Sortie", SNMPFormat.bytes(iface.outOctets))
                VStack(alignment: .leading, spacing: 2) {
                    Text("ERREURS EN ENTRÉE").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    let errors = iface.inErrors ?? 0
                    Text(iface.inErrors.map { SwitchText.grouped($0) } ?? "—")
                        .font(Theme.mono(12, weight: errors > 0 ? .semibold : .regular))
                        .foregroundStyle(errors >= 100 ? Theme.critical : Theme.text)
                }
                field("Dernier changement", SwitchText.lastChange(iface, uptime: snapshot.system.uptimeTicks), mono: false)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            divider

            VStack(alignment: .leading, spacing: 8) {
                SwitchFieldLabel("Appareils vus sur ce port (\(entries.count))")
                if entries.isEmpty {
                    Text("Aucune adresse MAC apprise sur ce port lors du dernier relevé.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                } else {
                    ForEach(entries.prefix(uplinks.contains(iface.index) ? 4 : 8), id: \.mac) { entry in
                        deviceRow(entry, neighbor: neighbor)
                    }
                    if entries.count > 8 || (uplinks.contains(iface.index) && entries.count > 4) {
                        Text("… et \(entries.count - (uplinks.contains(iface.index) ? 4 : 8)) autres (voir la table MAC)")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            divider

            if let neighbor {
                VStack(alignment: .leading, spacing: 6) {
                    SwitchFieldLabel(snapshot.isViaController ? (neighbor.portID == "FortiLink" ? "Lien FortiLink (FortiGate)" : "Lien inter-switch (ISL)") : "Voisin LLDP")
                    inline("Système", neighbor.sysName, mono: true)
                    inline("Port distant", neighbor.portID + (neighbor.portDescr.map { $0 == neighbor.portID ? "" : " (\($0))" } ?? ""), mono: true)
                    inline("Capacités", neighbor.capabilities.map { $0.labels.joined(separator: ", ") } ?? "—", mono: false)
                    if let descr = neighbor.sysDescr {
                        inline("Plateforme", descr, mono: false)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                divider
            }

            let primary = entries.first.map { store.describe($0.mac, devices: state.devices) }
            SwitchFlowLayout(spacing: 8) {
                Button { if let ip = primary?.ip, ip != "—" { state.sendToPing(ip) } } label: {
                    Label("Ping continu", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.primary)
                .disabled(primary?.ip == nil || primary?.ip == "—")
                Button("Fiche appareil") { if let id = primary?.deviceID { state.showDevice(id) } }
                    .buttonStyle(.secondary)
                    .disabled(primary?.deviceID == nil)
                Button(store.copiedPort == iface.index ? "Copié" : "Copier les infos") { copy(entries: entries, neighbor: neighbor, portState: portState) }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    private func vlanText(uplinks: Set<Int>) -> String {
        let pvid = snapshot.pvid[iface.index]
        if uplinks.contains(iface.index) {
            let vlans = Set(snapshot.entries(on: iface.index).compactMap(\.vlan)).sorted()
            let list = vlans.isEmpty ? "" : " · " + vlans.map(String.init).joined(separator: ",")
            return "Trunk" + (pvid.map { " · natif \($0)" } ?? "") + list
        }
        return pvid.map { "Accès \($0)" } ?? "—"
    }

    private func field(_ title: String, _ value: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ title: String, _ value: String, mono: Bool) -> some View {
        (Text("\(title)\u{00A0}: ").foregroundStyle(Theme.textSecondary) + Text(value).font(mono ? Theme.mono(12) : Theme.small))
            .font(Theme.small)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deviceRow(_ entry: SNMPFDBEntry, neighbor: SNMPLLDPNeighbor?) -> some View {
        let info = store.describe(entry.mac, devices: state.devices)
        let isNeighbor = store.isAnnounced(entry.mac, by: neighbor, devices: state.devices)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(info.name).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                SwitchSourceTag(source: snapshot.isViaController ? .fortigate : (isNeighbor ? .lldp : .fdb))
            }
            Text("\(info.ip) · \(entry.mac.formatted(.upperColon))").font(Theme.mono(12)).foregroundStyle(Theme.text)
            Text("\(info.vendor) · VLAN \((entry.vlan ?? snapshot.pvid[iface.index]).map(String.init) ?? "—") · vu \(SwitchText.ago(snapshot.polledAt))")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let id = info.deviceID { state.showDevice(id) } }
    }

    private func copy(entries: [SNMPFDBEntry], neighbor: SNMPLLDPNeighbor?, portState: SwitchPortState) {
        var lines = ["\(snapshot.displayName) · \(iface.name) · \(portState.label)"]
        if !iface.alias.isEmpty { lines.append(iface.alias) }
        lines.append("Vitesse\u{00A0}: \(SNMPFormat.speed(mbps: iface.speedMbps)) · VLAN\u{00A0}: \(snapshot.pvid[iface.index].map(String.init) ?? "—")")
        for entry in entries {
            let info = store.describe(entry.mac, devices: state.devices)
            lines.append("\(info.name) · \(info.ip) · \(entry.mac.formatted(.upperColon)) · \(info.vendor)")
        }
        if let neighbor { lines.append("Voisin LLDP\u{00A0}: \(neighbor.sysName) · \(neighbor.portID)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        store.copiedPort = iface.index
        let index = iface.index
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if store.copiedPort == index { store.copiedPort = nil }
        }
    }
}

extension SwitchText {
    /// « 1 284 » (espace insécable comme séparateur de milliers).
    static func grouped(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{00A0}"
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Table MAC / ports

/// Table MAC du switch affiché : tableau standard (note 8, clé « switchs.mac ») ; un clic sur une
/// ligne choisit son port sur la façade, et un port choisi sur la façade sélectionne sa première ligne.
struct SwitchMacTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    @ObservedObject private var inventory = InvModel.shared
    let snapshot: SNMPSwitchSnapshot
    @StateObject private var table = StandardTableModel<Row>(id: "switchs.mac", columns: Self.columns,
                                                             sortKeys: Self.sortKeys, defaultSort: "port")
    @State private var selection: Row.ID?

    /// Ligne de la table : une MAC apprise sur un port (valeurs affichées et clés de tri).
    struct Row: Identifiable {
        var id: String
        var ifIndex: Int
        var port: String
        var vlan: String
        var vlanSort: Int
        var mac: String
        var macSort: UInt64
        var ip: String
        var ipSort: UInt32
        var host: String
        var vendor: String
        var source: SwitchSource
        var seen: Date
        var deviceID: Device.ID?
        // Colonnes facultatives
        var customName: String?
        var type: DeviceType?
        var typeIsManual: Bool
        var oui: String
        var portAlias: String
        var poe: Bool?
        var poeText: String
        var portStatus: String
        var speed: String
        var speedSort: UInt64
        var location: String
        var locationCurrent: Bool
        var locationHelp: String

        /// Les valeurs absentes (« — ») vont en fin de liste en tri croissant.
        private static let last = "\u{10FFFF}"
        var hostSort: String { host == "—" ? Self.last : host.lowercased() }
        var vendorSort: String { vendor.lowercased() }
        var sourceSort: String { source.rawValue }
        var customNameSort: String { customName?.lowercased() ?? Self.last }
        var typeSort: String { type?.label ?? Self.last }
        var poeSort: Int { poe.map { $0 ? 0 : 1 } ?? 2 }
        var aliasSort: String { portAlias.isEmpty ? Self.last : portAlias.lowercased() }
        var locationSort: String { location == "—" ? Self.last : location }
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "port", title: "Port", isRequired: true),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "mac", title: "MAC"),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "hostname", title: "Hostname"),
        StandardColumn(id: "fabricant", title: "Fabricant"),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "vu", title: "Vu"),
        StandardColumn(id: "nom", title: "Nom personnalisé", isDefaultVisible: false),
        StandardColumn(id: "type", title: "Type", isDefaultVisible: false),
        StandardColumn(id: "oui", title: "OUI", isDefaultVisible: false),
        StandardColumn(id: "description", title: "Description du port", isDefaultVisible: false),
        StandardColumn(id: "poe", title: "PoE du port", isDefaultVisible: false),
        StandardColumn(id: "etat", title: "État du port", isDefaultVisible: false),
        StandardColumn(id: "vitesse", title: "Vitesse", isDefaultVisible: false),
        StandardColumn(id: "emplacement", title: "État de l’emplacement", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<Row>] = [
        "port": KeyPathComparator(\Row.ifIndex),
        "vlan": KeyPathComparator(\Row.vlanSort),
        "mac": KeyPathComparator(\Row.macSort),
        "ip": KeyPathComparator(\Row.ipSort),
        "hostname": KeyPathComparator(\Row.hostSort),
        "fabricant": KeyPathComparator(\Row.vendorSort),
        "source": KeyPathComparator(\Row.sourceSort),
        "vu": KeyPathComparator(\Row.seen),
        "nom": KeyPathComparator(\Row.customNameSort),
        "type": KeyPathComparator(\Row.typeSort),
        "oui": KeyPathComparator(\Row.oui),
        "description": KeyPathComparator(\Row.aliasSort),
        "poe": KeyPathComparator(\Row.poeSort),
        "etat": KeyPathComparator(\Row.portStatus),
        "vitesse": KeyPathComparator(\Row.speedSort),
        "emplacement": KeyPathComparator(\Row.locationSort),
    ]

    var body: some View {
        // Tri du tableau, puis port et MAC pour départager (ordre stable d'un relevé à l'autre).
        let rows = self.rows.sorted(using: table.sortOrder + [KeyPathComparator(\Row.ifIndex), KeyPathComparator(\Row.macSort)])
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Table MAC / ports").font(.system(size: 14, weight: .semibold)).fixedSize()
                // Le nom du switch est déjà dans l'en-tête de la façade : il passe en infobulle pour
                // laisser la place au bouton « Colonnes ».
                let mib = snapshot.fdb.contains { $0.vlan != nil } ? "Q-BRIDGE-MIB" : "BRIDGE-MIB"
                Text("\(rows.count) entrées · \(mib)")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
                    .help("\(rows.count) entrées · \(snapshot.displayName) · relevé SNMP \(mib)")
                Spacer(minLength: 0)
                Toggle("Masquer les uplinks", isOn: $store.hideUplinks)
                    .toggleStyle(.checkbox)
                    .font(Theme.small)
                    .fixedSize()
                TextField("Filtrer la table MAC", text: $store.tableFilter, prompt: Text("Filtrer port, VLAN, MAC, IP…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.small)
                    .frame(minWidth: 110, idealWidth: 180, maxWidth: 180)
                StandardColumnsMenu(model: table)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(!store.tableFilter.isEmpty ? "Aucune entrée ne correspond à «\u{00A0}\(store.tableFilter)\u{00A0}»."
                     : (state.searchText.isEmpty ? "Aucune adresse MAC apprise." : "Aucune entrée ne correspond à la recherche."))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                tableView(rows)
            }
        }
        .frame(height: 390)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .searchResults(rows.count, "entrée", "entrées")
    }

    private func tableView(_ rows: [Row]) -> some View {
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("PORT", sortUsing: table.sort("port")) { row in
                    SwitchCell(row.port, mono: true, strong: true).help(row.portAlias)
                }
                .width(min: 60, ideal: 70)
                .customizationID("port")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("VLAN", sortUsing: table.sort("vlan")) { row in SwitchCell(row.vlan, mono: true) }
                    .width(min: 36, ideal: 40)
                    .customizationID("vlan")

                TableColumn("MAC", sortUsing: table.sort("mac")) { row in SwitchCell(row.mac, mono: true) }
                    .width(min: 110, ideal: 128)
                    .customizationID("mac")

                TableColumn("IP", sortUsing: table.sort("ip")) { row in SwitchCell(row.ip, mono: true, dimmed: row.ip == "—") }
                    .width(min: 90, ideal: 104)
                    .customizationID("ip")

                TableColumn("HOSTNAME", sortUsing: table.sort("hostname")) { row in SwitchCell(row.host, dimmed: row.host == "—").help(row.host) }
                    .width(min: 70, ideal: 92)
                    .customizationID("hostname")

                TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { row in SwitchCell(row.vendor) }
                    .width(min: 60, ideal: 76)
                    .customizationID("fabricant")

                TableColumn("SOURCE", sortUsing: table.sort("source")) { row in SwitchSourceTag(source: row.source) }
                    .width(min: 56, ideal: 64)
                    .customizationID("source")

                TableColumn("VU", sortUsing: table.sort("vu")) { row in
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        SwitchCell(SwitchText.ago(row.seen), secondary: true)
                    }
                }
                .width(min: 60, ideal: 70)
                .customizationID("vu")
            }

            Group {
                TableColumn("NOM PERSONNALISÉ", sortUsing: table.sort("nom")) { row in
                    SwitchCell(row.customName ?? "—", dimmed: row.customName == nil)
                }
                .width(min: 80, ideal: 130)
                .customizationID("nom")
                .defaultVisibility(.hidden)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    if let type = row.type {
                        ScanTypeCell(type: type, isManual: row.typeIsManual)
                    } else {
                        SwitchCell("—", dimmed: true).help("Appareil absent du scan")
                    }
                }
                .width(min: 80, ideal: 140)
                .customizationID("type")
                .defaultVisibility(.hidden)

                TableColumn("OUI", sortUsing: table.sort("oui")) { row in SwitchCell(row.oui, mono: true) }
                    .width(min: 64, ideal: 76)
                    .customizationID("oui")
                    .defaultVisibility(.hidden)

                TableColumn("DESCRIPTION DU PORT", sortUsing: table.sort("description")) { row in
                    SwitchCell(row.portAlias.isEmpty ? "—" : row.portAlias, dimmed: row.portAlias.isEmpty)
                }
                .width(min: 80, ideal: 150)
                .customizationID("description")
                .defaultVisibility(.hidden)

                TableColumn("POE", sortUsing: table.sort("poe")) { row in
                    SwitchCell(row.poeText, dimmed: row.poe != true)
                }
                .width(min: 60, ideal: 120)
                .customizationID("poe")
                .defaultVisibility(.hidden)

                TableColumn("ÉTAT DU PORT", sortUsing: table.sort("etat")) { row in SwitchCell(row.portStatus) }
                    .width(min: 60, ideal: 120)
                    .customizationID("etat")
                    .defaultVisibility(.hidden)

                TableColumn("VITESSE", sortUsing: table.sort("vitesse")) { row in
                    SwitchCell(row.speed, mono: true, dimmed: row.speed == "—")
                }
                .width(min: 60, ideal: 80)
                .customizationID("vitesse")
                .defaultVisibility(.hidden)

                TableColumn("ÉTAT DE L’EMPLACEMENT", sortUsing: table.sort("emplacement")) { row in
                    SwitchCell(row.location, dimmed: !row.locationCurrent).help(row.locationHelp)
                }
                .width(min: 80, ideal: 150)
                .customizationID("emplacement")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        // Note 34 : double-clic ou ↩︎ → fiche de l'appareil ; MAC inconnue → son port (message clair).
        .standardRowActions(selection: selection.map { [$0] } ?? [], object: { id in
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            if let deviceID = row.deviceID, let device = state.device(withID: deviceID) { return .device(NavDeviceRef(device)) }
            return .port(NavPortRef(host: snapshot.id, ifIndex: row.ifIndex))
        }) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button("Copier la MAC") { copy(row.mac) }
                Button("Copier l’IP") { copy(row.ip) }.disabled(row.ip == "—")
                Divider()
                Button("Voir le port sur la façade") { store.select(host: snapshot.id, port: row.ifIndex) }
                Button("Voir la fiche complète") { if let id = row.deviceID { state.showDevice(id) } }
                    .disabled(row.deviceID == nil)
            }
        }
        .onAppear { followSelectedPort(rows) }
        .onChange(of: selection) { _, id in
            guard let row = rows.first(where: { $0.id == id }), row.ifIndex != store.selectedPort else { return }
            store.select(host: snapshot.id, port: row.ifIndex)
        }
        .onChange(of: store.selectedPort) { _, _ in followSelectedPort(rows) }
    }

    /// Sélectionne la première ligne du port choisi sur la façade (s'il n'en a pas déjà une).
    private func followSelectedPort(_ rows: [Row]) {
        guard let port = store.selectedPort else { return }
        if let current = rows.first(where: { $0.id == selection }), current.ifIndex == port { return }
        selection = rows.first { $0.ifIndex == port }?.id
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Ligne de la table MAC vue par la recherche : un mot seul lit les colonnes de l'ancien filtre
    /// (port, VLAN, MAC avec deux-points ou tirets, IP, nom, fabricant, source).
    static func searchItem(_ row: Row, switchName: String, site: String?) -> SearchDocument {
        var poe = [row.poeText]
        if row.poe == true { poe += ["Actif", "PoE"] } else if row.poe == false { poe.append("Inactif") }
        return SearchDocument([
            "port": [row.port], "vlan": [row.vlan], "nom": [row.host, row.customName ?? ""], "ip": [row.ip],
            "mac": [row.mac], "fab": [row.vendor], "type": row.type?.searchTerms ?? [], "etat": [row.portStatus],
            "poe": poe, "vitesse": [row.speed], "source": [row.source.rawValue], "switch": [switchName],
            "site": [site ?? ""],
        ], freeText: [row.port, row.vlan, row.mac, row.mac.replacingOccurrences(of: ":", with: "-"), row.ip, row.host,
                      row.vendor, row.source.rawValue])
    }

    private var rows: [Row] {
        let uplinks = snapshot.locatedUplinks
        // Note 26 : filtre du tableau et recherche de la barre d'outils, même moteur.
        let local = SearchQuery(store.tableFilter, schema: .switchs)
        let global = state.searchQuery(for: .switchs)
        let searching = !local.isEmpty || !global.isEmpty
        let switchName = snapshot.displayName
        let site = store.controllerName(forSwitch: switchName)
        // Appareils du scan par MAC, avec le type choisi à la main (note 20).
        var devices: [MACAddress: Device] = [:]
        for device in inventory.withManualTypes(state.devices) {
            if let mac = device.mac, devices[mac] == nil { devices[mac] = device }
        }
        var result: [Row] = []
        for entry in snapshot.fdb {
            guard let i = entry.ifIndex else { continue }
            let isUplink = uplinks.contains(i)
            if isUplink && store.hideUplinks { continue }
            let info = store.describe(entry.mac, devices: state.devices)
            let neighbor = snapshot.neighbor(on: i)
            let source: SwitchSource = isUplink ? .uplink
                : (snapshot.isViaController ? .fortigate : (store.isAnnounced(entry.mac, by: neighbor, devices: state.devices) ? .lldp : .fdb))
            let iface = snapshot.interface(i)
            let device = devices[entry.mac]
            let vlan = entry.vlan ?? snapshot.pvid[i]
            let located = device?.switchName != nil
            let status = located ? device.map { state.locationStatus($0) } : nil
            let macText = entry.mac.formatted(.upperColon)
            let row = Row(id: "\(i)-\(entry.mac)-\(entry.vlan ?? 0)", ifIndex: i, port: iface?.name ?? "\(entry.bridgePort)",
                          vlan: vlan.map(String.init) ?? "—", vlanSort: vlan ?? Int.max,
                          mac: macText, macSort: entry.mac.value,
                          ip: info.ip, ipSort: IPv4Address(info.ip)?.value ?? UInt32.max,
                          host: info.name, vendor: info.vendor, source: source, seen: snapshot.polledAt,
                          deviceID: info.deviceID,
                          customName: device?.customName, type: device?.deviceType,
                          typeIsManual: device.map { inventory.typeChoice(for: $0).isManual } ?? false,
                          oui: String(macText.prefix(8)), portAlias: iface?.alias ?? "",
                          poe: iface.map { _ in snapshot.poePort(i)?.isDelivering == true },
                          poeText: iface.map { SwitchText.poeLine($0, snapshot: snapshot) } ?? "—",
                          portStatus: iface.map { "\($0.adminUp ? "Activé" : "Désactivé") / \($0.operStatus.label)" } ?? "—",
                          speed: iface.flatMap { $0.isUp ? SNMPFormat.speed(mbps: $0.speedMbps) : nil } ?? "—",
                          speedSort: iface.flatMap { $0.isUp ? $0.speedMbps : nil } ?? 0,
                          location: status.map(ScanDeviceTable.locationLabel) ?? "—",
                          locationCurrent: status?.isCurrent == true,
                          locationHelp: status.map { $0.explanation ?? "Relevé sur le réseau actuel" } ?? "")
            if searching {
                let item = Self.searchItem(row, switchName: switchName, site: site)
                if !(local.matches(item) && global.matches(item)) { continue }
            }
            result.append(row)
        }
        return result
    }
}

/// Texte d'une cellule des tableaux de l'écran Switchs.
struct SwitchCell: View {
    let text: String
    var mono = false
    var dimmed = false
    var secondary = false
    var strong = false

    init(_ text: String, mono: Bool = false, dimmed: Bool = false, secondary: Bool = false, strong: Bool = false) {
        self.text = text
        self.mono = mono
        self.dimmed = dimmed
        self.secondary = secondary
        self.strong = strong
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(12, weight: strong ? .semibold : .regular) : Theme.small)
            .foregroundStyle(dimmed ? Theme.textTertiary : (secondary ? Theme.textSecondary : Theme.text))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 20)
    }
}

// MARK: - Topologie simplifiée

struct SwitchTopology: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore

    var body: some View {
        let chain = orderedChain
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Topologie").font(.system(size: 14, weight: .semibold))
                    Text("déduite par LLDP").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 13))
                        Text("Internet").font(Theme.bodyMedium)
                        Spacer()
                    }
                    .foregroundStyle(Theme.neutralText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(width: 230)
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0x9CA3AF), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    link(nil, color: Color(hex: 0x9CA3AF), width: 2)
                    if let gateway = gatewayDevice {
                        node(title: gateway.hostnameLabel ?? gateway.displayName, subtitle: "\(gateway.id) · passerelle", mono: false, active: false, muted: true) {}
                        link(gatewayLink(chain.first), color: Theme.accent, width: 2)
                    }
                    ForEach(Array(chain.enumerated()), id: \.element.id) { position, snapshot in
                        node(title: snapshot.displayName, subtitle: "\(snapshot.id) · \(SwitchText.shortModel(snapshot))", mono: true,
                             active: store.current?.id == snapshot.id, muted: false) {
                            store.select(host: snapshot.id, port: uplinkPort(of: snapshot))
                        }
                        if position + 1 < chain.count {
                            link(linkText(snapshot, chain[position + 1]), color: Theme.accent, width: 4)
                        }
                    }
                    if chain.isEmpty {
                        Text("Aucun switch interrogé.").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                    }
                    vlanBlocks
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var gatewayDevice: Device? {
        guard let gateway = state.activeInterface?.gateway else { return nil }
        return state.devices.first { $0.ip == gateway }
    }

    /// Switchs dans l'ordre des liens LLDP, en partant de celui qui voit la passerelle.
    private var orderedChain: [SNMPSwitchSnapshot] {
        let all = store.orderedSnapshots
        guard !all.isEmpty else { return [] }
        let gatewayName = gatewayDevice?.hostname?.lowercased()
        let root = all.first { s in s.neighbors.contains { $0.sysName.lowercased() == gatewayName } } ?? all[0]
        var result = [root]
        var queue = [root]
        while let current = queue.first {
            queue.removeFirst()
            for neighbor in current.neighbors {
                if let next = all.first(where: { $0.displayName.caseInsensitiveCompare(neighbor.sysName) == .orderedSame }),
                   !result.contains(where: { $0.id == next.id }) {
                    result.append(next)
                    queue.append(next)
                }
            }
        }
        result += all.filter { s in !result.contains { $0.id == s.id } }
        return result
    }

    private func gatewayLink(_ root: SNMPSwitchSnapshot?) -> String? {
        guard let root, let name = gatewayDevice?.hostname?.lowercased(),
              let neighbor = root.neighbors.first(where: { $0.sysName.lowercased() == name }) else { return nil }
        let local = neighbor.ifIndex.flatMap { root.interface($0)?.name } ?? "?"
        return "\(neighbor.portID) ↔ \(local) · trunk"
    }

    private func linkText(_ a: SNMPSwitchSnapshot, _ b: SNMPSwitchSnapshot) -> String? {
        guard let neighbor = a.neighbors.first(where: { $0.sysName.caseInsensitiveCompare(b.displayName) == .orderedSame }) else { return nil }
        let iface = neighbor.ifIndex.flatMap { a.interface($0) }
        let speed = iface.map { " · " + SNMPFormat.speed(mbps: $0.speedMbps) } ?? ""
        return "\(iface?.name ?? "?") ↔ \(neighbor.portID)\(speed)"
    }

    private func uplinkPort(of snapshot: SNMPSwitchSnapshot) -> Int? {
        snapshot.locatedUplinks.sorted().first
    }

    private func link(_ text: String?, color: Color, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: width / 2).fill(color).frame(width: width, height: 26)
            if let text { Text(text).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary) }
        }
        .frame(height: 28)
    }

    @ViewBuilder private func node(title: String, subtitle: String, mono: Bool, active: Bool, muted: Bool, action: @escaping () -> Void) -> some View {
        let box = VStack(alignment: .leading, spacing: 2) {
            Text(title).font(mono ? Theme.mono(13, weight: .semibold) : Theme.bodySemibold).foregroundStyle(Theme.text)
            Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(active ? Theme.accentSoft : (muted ? Theme.panelMuted : Theme.panel)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(active ? Theme.accent : Theme.border, lineWidth: active ? 2 : 1))
        if muted {
            box
        } else {
            Button(action: action) { box.contentShape(Rectangle()) }.buttonStyle(.plain)
        }
    }

    /// Les deux VLAN qui portent le plus d'appareils sur des ports d'accès.
    @ViewBuilder private var vlanBlocks: some View {
        let counts = vlanCounts
        if !counts.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(counts.prefix(2), id: \.vlan) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VLAN \(item.vlan)").font(Theme.captionSemibold).foregroundStyle(Theme.text)
                        Text("\(item.count) appareil\(item.count > 1 ? "s" : "") en accès").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        Text(item.ports).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x9CA3AF)).frame(height: 2) }
                }
            }
            .frame(width: 250)
        }
    }

    private var vlanCounts: [(vlan: Int, count: Int, ports: String)] {
        var map: [Int: (Int, [String])] = [:]
        for snapshot in store.orderedSnapshots {
            let uplinks = snapshot.locatedUplinks
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex, !uplinks.contains(i), let vlan = entry.vlan ?? snapshot.pvid[i], vlan != 1 else { continue }
                var item = map[vlan] ?? (0, [])
                item.0 += 1
                if let name = snapshot.interface(i)?.name, item.1.count < 3, !item.1.contains(name) { item.1.append(name) }
                map[vlan] = item
            }
        }
        return map.map { (vlan: $0.key, count: $0.value.0, ports: $0.value.1.joined(separator: ", ")) }
            .sorted { $0.count > $1.count }
    }
}

/// Disposition en lignes qui passent à la ligne suivante quand la largeur manque (flex-wrap).
struct SwitchFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
