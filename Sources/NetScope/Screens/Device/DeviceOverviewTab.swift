import NetScopeCore
import SwiftUI

/// Ligne clé / valeur des cartes de la fiche : clé grise à gauche, valeur SF Mono à droite, filet.
struct DeviceKVRow: View {
    let key: String
    let value: String
    var mono = true
    var valueColor: Color = Theme.text
    /// Précision après la valeur (« mDNS (Bonjour) ») : sur la même ligne si tout tient, sinon
    /// entière sur la ligne suivante (jamais coupée au milieu).
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
            Spacer(minLength: 8)
            if let detail {
                ViewThatFits(in: .horizontal) {
                    valueText(value + " · " + detail).fixedSize()
                    VStack(alignment: .trailing, spacing: 1) {
                        valueText(value)
                        valueText(detail)
                    }
                }
            } else {
                valueText(value)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(mono ? Theme.mono(12.5) : .system(size: 12.5))
            .foregroundStyle(valueColor)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .lineLimit(2)
    }
}

/// Carte de la fiche (intertitre en petites majuscules, panneau blanc).
struct DeviceCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolFieldLabel(title)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Onglet Aperçu : Réseau, Matériel, Emplacement physique, Disponibilité, Services connus.
struct DeviceOverviewTab: View {
    @EnvironmentObject private var state: AppState
    /// Emplacements relevés (note 18) : un ancien relevé est grisé comme dans le Scanner.
    @ObservedObject private var switches = SwitchStore.shared
    /// Notes 27 et 46 : client Wi-Fi vu par la FortiGate (section Wi-Fi sous les cartes).
    @ObservedObject private var fortiAP = FortiAPStore.shared
    let device: Device
    var onScanPorts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                networkCard
                hardwareCard
                locationCard
                // Note 91 : consommables des imprimantes (SNMP, Printer-MIB), en tête de la 2e rangée.
                if device.deviceType == .imprimante {
                    DevicePrinterCard(device: device)
                }
                availabilityCard
                servicesCard
                // Note 68 : empreinte légère (système, confiance, versions, indices).
                DeviceFingerprintCard(device: device)
            }
            // Notes 27 et 46 : client Wi-Fi vu par la FortiGate du site actif, tout ce qui sert au diagnostic.
            if let client = fortiAP.client(for: device) {
                DeviceWifiSection(device: device, client: client)
            }
        }
    }

    // MARK: Réseau

    private var subnet: Subnet? {
        for range in state.ranges {
            if let subnet = try? Subnet(parsing: range.text), subnet.contains(device.ip) { return subnet }
        }
        if let iface = state.activeInterface, iface.subnet.contains(device.ip) { return iface.subnet }
        return nil
    }

    private var networkCard: some View {
        DeviceCard(title: "Réseau") {
            VStack(spacing: 0) {
                DeviceKVRow(key: "Adresse IPv4", value: device.ip.description)
                // IPv6 (0.31.0) : adresses rattachées par la MAC (table NDP) : lien local, ULA, globales.
                ForEach(device.ipv6 ?? [], id: \.self) { address in
                    // Adresse sur une ligne (réduite au besoin), jamais coupée en deux.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.ipv6Key(address)).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                        Spacer(minLength: 8)
                        Text(address.description).font(Theme.mono(12.5)).foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                    .help("\(address.scope.label) · forme complète \(address.expanded)"
                          + (address.embeddedMAC != nil ? " · identifiant EUI-64" : ""))
                }
                if (device.ipv6 ?? []).isEmpty {
                    DeviceKVRow(key: "IPv6", value: "Aucune adresse vue", mono: false, valueColor: Theme.textSecondary)
                }
                DeviceKVRow(key: "Masque", value: subnet.map { "\($0.mask) (/\($0.prefix))" } ?? "Inconnu")
                DeviceKVRow(key: "Réseau", value: subnet?.description ?? "—")
                DeviceKVRow(key: "Passerelle", value: gatewayText)
                DeviceKVRow(key: "DNS", value: state.dnsServers.isEmpty ? "—" : state.dnsServers.map(\.description).joined(separator: ", "))
                DeviceKVRow(key: "Plage", value: [device.rangeLabel, device.vlan.map { "VLAN \($0)" }].compactMap { $0 }.joined(separator: " · ").toolIfEmpty("—"), mono: false)
                DeviceKVRow(key: "Nom d’hôte", value: device.hostnameLabel ?? "—",
                            detail: device.hostnameLabel == nil ? nil : device.nameSourceLabel)
            }
        }
    }

    static func ipv6Key(_ address: IPv6Address) -> String {
        switch address.scope {
        case .linkLocal: return "IPv6 lien local"
        case .uniqueLocal: return "IPv6 ULA"
        case .global, .documentation: return "IPv6 globale"
        default: return "IPv6 · \(address.scope.label.lowercased())"
        }
    }

    private var gatewayText: String {
        guard let iface = state.activeInterface, let gateway = iface.gateway, iface.subnet.contains(device.ip) else { return "—" }
        if let name = state.device(withID: gateway.description)?.hostname { return "\(gateway) · \(name)" }
        return gateway.description
    }

    // MARK: Matériel

    private var hardwareCard: some View {
        DeviceCard(title: "Matériel") {
            VStack(spacing: 0) {
                DeviceKVRow(key: "MAC", value: device.mac?.formatted(.upperColon) ?? "Inconnue")
                if let mac = device.mac {
                    let info = MACVendorLookup.info(for: mac)
                    DeviceKVRow(key: "Fabricant (OUI)", value: "\(device.vendorLabel) · \(info.oui)")
                    DeviceKVRow(key: "Type d’adresse", value: mac.isRandomized ? "Privée (aléatoire)" : info.kind, mono: false,
                                valueColor: mac.isRandomized ? Theme.warning : Theme.text)
                } else {
                    DeviceKVRow(key: "Fabricant", value: device.vendorLabel)
                }
                DeviceKVRow(key: "Famille", value: device.deviceType.label, mono: false)
                // Note 30 : ce qui fait d'un appareil un téléphone IP.
                // Le nom d'hôte est sur la ligne « Modèle / hôte » juste dessous.
                let evidence = device.deviceType == .telephoneIP ? VoIPClassifier.evidence(device, includeName: false) : []
                if !evidence.isEmpty {
                    DeviceKVRow(key: "Indices VoIP", value: evidence.joined(separator: " · "), mono: false)
                }
                DeviceKVRow(key: "Modèle / hôte", value: device.hostname ?? "—")
                DeviceKVRow(key: "Ports ouverts", value: device.openPorts.isEmpty ? "aucun connu"
                            : "\(device.openPorts.count) · " + device.openPorts.prefix(6).map(String.init).joined(separator: ", "))
                // Note 60 : modèle, numéro de série et firmware lus par SNMP ou par la FortiGate.
                DeviceDetectedHardwareRows(device: device)
            }
        }
    }

    // MARK: Emplacement physique

    private var locationCard: some View {
        DeviceCard(title: "Emplacement physique") {
            if let switchName = device.switchName {
                let switchDevice = state.devices.first { $0.hostname == switchName || $0.customName == switchName }
                // Client Wi-Fi : la borne vient de la FortiGate (toutes les FortiAP d'un même modèle
                // portent le même nom d'hôte, « FortiAP-231F » ne suffit pas à trouver la bonne).
                let wifiAP = device.switchPort == "Wi-Fi" ? fortiAP.client(for: device).flatMap(fortiAP.ap(for:)) : nil
                let status = state.locationStatus(device)
                VStack(alignment: .leading, spacing: 10) {
                    if let explanation = status.explanation {
                        Text(explanation).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Switch et port gardent leur largeur ; le nom de l'appareil tient sur une ligne
                    // quand la place le permet, sinon passe sur deux lignes en coupant à un espace
                    // (traits d'union insécables : « Brother / DCP‑L2640DW », jamais « DCP- / L2640DW » ; coupure
                    // permise après un point : « Macmini‑de‑Dany. / local », jamais « .loc / al » ; de même après « _ » : « Android_ / 89UM1WTN »).
                    let deviceName = device.hostname ?? device.displayName
                    HStack(spacing: 4) {
                        node(title: wifiAP?.name ?? switchName,
                             detail: wifiAP.map { $0.ip?.description ?? $0.model } ?? switchDevice?.ip.description ?? "switch", highlighted: false)
                            .fixedSize()
                        Text("─").foregroundStyle(Theme.textSecondary)
                        node(title: device.switchPort ?? "?", detail: device.vlan.map { "VLAN \($0)" } ?? "port", highlighted: true)
                            .fixedSize()
                        Text("─").foregroundStyle(Theme.textSecondary)
                        ViewThatFits(in: .horizontal) {
                            node(title: deviceName, detail: ".\(device.ip.octets.3)", highlighted: false)
                                .fixedSize()
                            node(title: deviceName.replacingOccurrences(of: "-", with: "\u{2011}").replacingOccurrences(of: ".", with: ".\u{200B}")
                                    .replacingOccurrences(of: "_", with: "_\u{200B}"),
                                 detail: ".\(device.ip.octets.3)", highlighted: false, titleLines: 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(status.isCurrent ? 1 : 0.55)
                    VStack(spacing: 0) {
                        if let wifiAP {
                            DeviceKVRow(key: "Borne", value: "\(wifiAP.name) · \(wifiAP.model)")
                        } else {
                            DeviceKVRow(key: "Switch", value: switchName + (switchDevice.map { " · \($0.vendorLabel)" } ?? ""))
                        }
                        DeviceKVRow(key: "Port", value: device.switchPort ?? "Inconnu")
                        DeviceKVRow(key: "VLAN", value: device.vlan.map(String.init) ?? "Inconnu")
                        if device.switchPort != "Wi-Fi" {
                            // Note 12 : PoE du port, d'après le relevé SNMP du switch.
                            let poe = SwitchStore.shared.poeStatus(for: device)
                            DeviceKVRow(key: "PoE", value: poe?.detailLabel ?? "Inconnu · switch non relevé ou port absent du relevé SNMP", mono: false,
                                        valueColor: poe?.isPowered == true ? Theme.success : Theme.text)
                        }
                        if let controller = switches.controllerName(forSwitch: switchName) {
                            // Note 24 : FortiSwitch géré par FortiLink, lu par la FortiGate.
                            DeviceKVRow(key: "Source", value: status.isCurrent ? "FortiGate · \(controller) (appareils détectés, FortiLink)"
                                        : "Ancienne lecture de la FortiGate (non confirmée)", mono: false)
                        } else {
                            DeviceKVRow(key: "Source", value: status.isCurrent ? "Inventaire (dernier relevé des switchs)"
                                        : "Ancien relevé des switchs (non confirmé)", mono: false)
                        }
                    }
                    .opacity(status.isCurrent ? 1 : 0.55)
                    Button("Voir le port dans Switchs et ports →") { state.showSwitchPort(switchName: device.switchName, port: device.switchPort) }
                        .buttonStyle(.ghost)
                        .padding(.leading, -8)
                    // Note 73 : cycle PoE et redémarrage du port de l'appareil (si autorisés).
                    if status.isCurrent { PortActionDeviceRow(device: device) }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.diamond").foregroundStyle(Theme.textTertiary)
                        Text("Inconnu — interroger les switchs").font(Theme.bodySemibold)
                    }
                    Text("L’emplacement (switch, port, VLAN) vient de la table MAC des switchs, lue par SNMP. Aucun relevé ne contient encore la MAC de cet appareil.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ouvrir Switchs et ports") { state.open(.switchs) }.buttonStyle(.secondary)
                }
            }
        }
    }

    private func node(title: String, detail: String, highlighted: Bool, titleLines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(titleLines)
            Text(detail).font(Theme.mono(11)).foregroundStyle(highlighted ? Theme.accentStrong : Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(highlighted ? Theme.accent : Theme.border))
    }

    // MARK: Disponibilité

    private var availabilityCard: some View {
        DeviceCard(title: "Disponibilité") {
            if let manual = state.manualEntry(forID: device.id) {
                manualAvailability(manual)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ToolStatTile(label: "État", value: device.isOnline ? "En ligne" : "Hors ligne",
                                     valueColor: device.isOnline ? Theme.success : Theme.textSecondary)
                        ToolStatTile(label: "Latence", value: device.latencyMs.map(ToolFormat.milliseconds) ?? "—")
                        ToolStatTile(label: "Dernière vue", value: ToolText.relative(device.lastSeen))
                    }
                    VStack(spacing: 0) {
                        DeviceKVRow(key: "Première détection", value: DeviceFormat.date(device.firstSeen))
                        DeviceKVRow(key: "Dernière détection", value: DeviceFormat.date(device.lastSeen))
                        DeviceKVRow(key: "Suivi depuis", value: DeviceFormat.span(from: device.firstSeen), mono: false)
                    }
                    Text("Le détail heure par heure viendra avec la Surveillance.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// Appareil hors Scanner (saisi à la main, ou fiche reprise) : son état ici ne vient que de
    /// « Vérifier maintenant » (un ping, sur demande) ; une fiche reprise donne son dernier état connu.
    private func manualAvailability(_ entry: ManualDeviceEntry) -> some View {
        let check = entry.lastCheck
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolStatTile(label: "État", value: check.map { $0.isOnline ? "En ligne" : "Ne répond pas" } ?? "Non vérifié",
                             valueColor: check?.isOnline == true ? Theme.success : Theme.textSecondary)
                ToolStatTile(label: "Latence", value: check?.latencyMs.map(ToolFormat.milliseconds) ?? "—")
                ToolStatTile(label: "Vérifié", value: check.map { ToolText.relative($0.date) } ?? "jamais")
            }
            VStack(spacing: 0) {
                DeviceKVRow(key: "\(entry.createdVerb) le", value: DeviceFormat.date(entry.created))
                DeviceKVRow(key: "Dernière vérification", value: check.map { DeviceFormat.date($0.date) } ?? "—")
                if let base = entry.base {
                    DeviceKVRow(key: "Dernière détection (ailleurs)", value: DeviceFormat.date(base.lastSeen))
                } else {
                    DeviceKVRow(key: "Vu par un scan", value: "pas encore", mono: false)
                }
            }
            Text("«\u{00A0}Vérifier maintenant\u{00A0}» envoie un seul ping\u{00A0}; un scan qui voit cet appareil le rattache.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Services

    private var servicesCard: some View {
        DeviceCard(title: "Services connus") {
            VStack(alignment: .leading, spacing: 10) {
                if device.openPorts.isEmpty {
                    Text("Aucun port ouvert connu. Lancez un scan de ports pour découvrir les services.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ToolFlowLayout(spacing: 6) {
                        ForEach(device.openPorts, id: \.self) { port in
                            PortTag(port: port, showService: true, tone: PortScanner.webScheme(for: port) != nil ? .accent : .neutral)
                                .help(RustDeskPorts.isRustDeskPort(port)
                                      ? RustDeskPorts.help(port: port, role: RustDeskPorts.role(openPorts: device.openPorts)) : "")
                        }
                    }
                    // Note 6 : serveur RustDesk (rôle des ports, test) ou poste à accès IP direct.
                    RustDeskDeviceFinding(device: device)
                }
                HStack(spacing: 8) {
                    Button("Scanner les ports", action: onScanPorts).buttonStyle(.secondary)
                    if device.openPorts.contains(where: { PortScanner.webScheme(for: $0) != nil }) {
                        ForEach(DeviceSession.webURLs(for: device).prefix(2), id: \.self) { text in
                            let url = URL(string: text)
                            Button("Ouvrir " + (url?.scheme ?? "web") + (url?.port.map { " :\($0)" } ?? "")) {
                                ToolActions.open(text)
                            }
                            .buttonStyle(.ghost)
                        }
                    }
                }
            }
        }
    }
}

enum DeviceFormat {
    /// « 2026-10-20 09:42 ».
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// « 14 jours », « aujourd’hui ».
    static func span(from date: Date, now: Date = Date()) -> String {
        let days = (now.timeIntervalSince(date) / 86_400).rounded(.towardZero).clampedInt
        switch days {
        case ..<1: return "aujourd’hui"
        case 1: return "1 jour"
        default: return "\(days) jours"
        }
    }
}
