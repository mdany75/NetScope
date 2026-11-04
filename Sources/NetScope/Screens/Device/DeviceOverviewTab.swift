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
    /// Note 27 : client Wi-Fi vu par la FortiGate (borne FortiAP, SSID, bande, signal).
    @ObservedObject private var fortiAP = FortiAPStore.shared
    let device: Device
    var onScanPorts: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            networkCard
            hardwareCard
            locationCard
            if let client = fortiAP.client(for: device) {
                DeviceFortiAPCard(device: device, client: client)
            }
            availabilityCard
            servicesCard
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
                DeviceKVRow(key: "Modèle / hôte", value: device.hostname ?? "—")
                DeviceKVRow(key: "Ports ouverts", value: device.openPorts.isEmpty ? "aucun connu"
                            : "\(device.openPorts.count) · " + device.openPorts.prefix(6).map(String.init).joined(separator: ", "))
            }
        }
    }

    // MARK: Emplacement physique

    private var locationCard: some View {
        DeviceCard(title: "Emplacement physique") {
            if let switchName = device.switchName {
                let switchDevice = state.devices.first { $0.hostname == switchName || $0.customName == switchName }
                let status = state.locationStatus(device)
                VStack(alignment: .leading, spacing: 10) {
                    if let explanation = status.explanation {
                        Text(explanation).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Switch et port gardent leur largeur ; le nom de l'appareil tient sur une ligne
                    // quand la place le permet, sinon passe sur deux lignes en coupant à un espace
                    // (traits d'union insécables : « Brother / DCP‑L2640DW », jamais « DCP- / L2640DW » ; coupure
                    // permise après un point : « Macmini‑de‑Dany. / local », jamais « .loc / al »).
                    let deviceName = device.hostname ?? device.displayName
                    HStack(spacing: 4) {
                        node(title: switchName, detail: switchDevice?.ip.description ?? "switch", highlighted: false)
                            .fixedSize()
                        Text("─").foregroundStyle(Theme.textSecondary)
                        node(title: device.switchPort ?? "?", detail: device.vlan.map { "VLAN \($0)" } ?? "port", highlighted: true)
                            .fixedSize()
                        Text("─").foregroundStyle(Theme.textSecondary)
                        ViewThatFits(in: .horizontal) {
                            node(title: deviceName, detail: ".\(device.ip.octets.3)", highlighted: false)
                                .fixedSize()
                            node(title: deviceName.replacingOccurrences(of: "-", with: "\u{2011}").replacingOccurrences(of: ".", with: ".\u{200B}"),
                                 detail: ".\(device.ip.octets.3)", highlighted: false, titleLines: 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(status.isCurrent ? 1 : 0.55)
                    VStack(spacing: 0) {
                        DeviceKVRow(key: "Switch", value: switchName + (switchDevice.map { " · \($0.vendorLabel)" } ?? ""))
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
                    Button("Voir le port dans Switchs et ports →") { state.open(.switchs) }
                        .buttonStyle(.ghost)
                        .padding(.leading, -8)
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
                        }
                    }
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
