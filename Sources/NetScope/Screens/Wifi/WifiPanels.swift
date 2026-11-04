import NetScopeCore
import SwiftUI

// Blocs de l'analyseur Wi-Fi, dans l'ordre du croquis Wifi.dc.html.

/// Intertitre du croquis Wi-Fi (11 pt, majuscules, espacement).
struct WifiHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(Theme.captionSemibold).kerning(0.5).foregroundStyle(Theme.textSecondary)
    }
}

/// Barre de signal (RSSI).
struct WifiSignalBar: View {
    let rssi: Int
    var width: CGFloat = 64
    var height: CGFloat = 6

    var body: some View {
        let color = WifiText.qualityColor(rssi).foreground
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2).fill(Theme.border)
            RoundedRectangle(cornerRadius: height / 2).fill(color)
                .frame(width: width * CGFloat(WifiQuality.percent(rssi: rssi)) / 100)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// Pastille arrondie (« Connecté », « WPA3-Entreprise »).
struct WifiPill: View {
    let text: String
    var foreground: Color = Theme.neutralText
    var background: Color = Theme.neutralSoft
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize()
    }

    static func security(_ security: WifiSecurity) -> WifiPill {
        if security.isOpen || security == .wep { return WifiPill(text: security.label, foreground: Theme.critical, background: Theme.criticalSoft) }
        if security.isWPA3 { return WifiPill(text: security.label, foreground: Theme.success, background: Theme.successSoft) }
        return WifiPill(text: security.label)
    }
}

// MARK: - Connexion actuelle

struct WifiConnectionPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: WifiStore
    @State private var showRoams = false

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                if store.noInterface {
                    EmptyState(systemImage: "wifi.slash", title: "Aucune interface Wi-Fi",
                               message: "Ce Mac n’a pas d’interface Wi-Fi active (CoreWLAN n’en trouve aucune).")
                        .frame(height: 140)
                } else if let connection = store.connection, connection.powerOn, let network = connection.network {
                    header(network)
                    if store.namesRedacted { locationBanner }
                    tiles(connection, network)
                    if showRoams { roamTable }
                } else {
                    HStack(spacing: 12) {
                        icon
                        VStack(alignment: .leading, spacing: 2) {
                            WifiHeading("Connexion actuelle")
                            Text(store.connection?.powerOn == false ? "Wi-Fi désactivé" : "Non connecté")
                                .font(.system(size: 16, weight: .bold))
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft)
            Image(systemName: "wifi").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accentStrong)
        }
        .frame(width: 34, height: 34)
    }

    private func header(_ network: WifiNetwork) -> some View {
        let quality = WifiQuality(rssi: network.rssi)
        let colors = WifiText.qualityColor(network.rssi)
        return HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                WifiHeading("Connexion actuelle")
                HStack(spacing: 8) {
                    Text(store.label(for: network)).font(.system(size: 16, weight: .bold))
                    WifiPill(text: "Connecté", foreground: Theme.success, background: Theme.successSoft)
                    if let standard = network.standard { WifiPill(text: WifiConnectionPanel.generation(standard)) }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Text("Qualité").font(Theme.small).foregroundStyle(Theme.textSecondary)
                WifiSignalBar(rssi: network.rssi, width: 120, height: 8)
                Text(quality.longLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.foreground)
            }
            if let me = myDevice {
                Button("Fiche de ce Mac") { state.showDevice(me.id) }.buttonStyle(.secondary)
            }
        }
    }

    private var myDevice: Device? {
        guard let address = state.activeInterface?.address else { return nil }
        return state.devices.first { $0.ip == address }
    }

    /// « Wi-Fi 6 (802.11ax) ».
    static func generation(_ standard: String) -> String {
        switch standard {
        case "802.11be": return "Wi-Fi 7 (802.11be)"
        case "802.11ax": return "Wi-Fi 6 (802.11ax)"
        case "802.11ac": return "Wi-Fi 5 (802.11ac)"
        case "802.11n": return "Wi-Fi 4 (802.11n)"
        default: return standard
        }
    }

    /// Le bouton suit l'état de l'autorisation (WifiLocationGuidance) ; le message sous le texte
    /// dit ce qui se passe et ce qu'il faut faire.
    private var locationBanner: some View {
        let guidance = store.locationGuidance
        return HStack(spacing: 10) {
            Image(systemName: "location.slash").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS masque le nom du réseau (SSID) et le BSSID").font(Theme.bodySemibold)
                Text("Depuis macOS 14, lire le SSID exige l’autorisation de localisation. NetScope ne s’en sert que pour lire le nom des réseaux Wi-Fi.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(guidance.message)
                    .font(Theme.small.weight(guidance.isWarning ? .semibold : .regular))
                    .foregroundStyle(guidance.isWarning ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(guidance.buttonTitle) { store.requestLocation() }
                .buttonStyle(.primary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft))
    }

    private func tiles(_ connection: WifiStore.Connection, _ network: WifiNetwork) -> some View {
        let ap = accessPoint(for: network)
        let colors = WifiText.qualityColor(network.rssi)
        let block = WifiText.block(network).map { " (\($0))" } ?? ""
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 8)], spacing: 8) {
            tile("BSSID", network.bssid?.formatted(.upperColon) ?? "masqué", mono: true)
            tile("Point d’accès", ap?.displayName ?? WifiText.vendor(network), sub: ap?.id ?? (network.bssid == nil ? nil : "fabricant d’après le BSSID"))
            if let ap, let switchName = ap.switchName {
                tile("Branché sur", switchName, sub: ap.switchPort, mono: true, accent: true) { state.open(.switchs) }
            } else {
                tile("Interface", connection.interfaceName, sub: connection.hardwareAddress?.uppercased(), mono: true)
            }
            tile("Bande / canal", "\(network.band.label) · canal \(network.channel)", sub: "Largeur \(network.widthMHz)\u{00A0}MHz\(block)")
            tileColored("RSSI · direct", WifiQuality.dbm(network.rssi), color: colors.foreground,
                        sub: network.noise.map { "Bruit \(WifiQuality.dbm($0))" })
            tile("SNR", network.snr.map { "\($0)\u{00A0}dB" } ?? "—", sub: "Excellent au-delà de 25\u{00A0}dB", mono: true, subMono: false)
            tile("Débit PHY", connection.transmitRate.map { "\(Int($0))\u{00A0}Mb/s" } ?? "—", sub: network.standard.map(WifiConnectionPanel.generation), mono: true, subMono: false)
            tileColored("Sécurité", network.security.label, color: network.security.isOpen ? Theme.critical : (network.security.isWPA3 ? Theme.success : Theme.text),
                        sub: network.security.isOpen ? "aucun chiffrement" : nil, mono: false)
            tile("VLAN / IP", myDevice?.vlan.map { "VLAN \($0)" } ?? (state.activeInterface?.address.description ?? "—"),
                 sub: myDevice?.vlan == nil ? state.activeInterface?.subnet.description : state.activeInterface?.address.description, mono: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Itinérance").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Text(store.roams.isEmpty ? "Aucun changement d’AP" : "\(store.roams.count) changement\(store.roams.count > 1 ? "s" : "") d’AP")
                    .font(.system(size: 12, weight: .semibold))
                if !store.roams.isEmpty {
                    Button(showRoams ? "Masquer l’historique" : "Voir l’historique") { showRoams.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accentStrong)
                } else {
                    Text("depuis l’ouverture").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .modifier(WifiTileStyle())
        }
    }

    /// Point d'accès du scan dont la MAC partage le préfixe du BSSID (même boîtier, MAC voisine).
    private func accessPoint(for network: WifiNetwork) -> Device? {
        guard let bssid = network.bssid else { return nil }
        let candidates = state.devices.filter { $0.deviceType == .pointAcces && $0.mac?.ouiValue == bssid.ouiValue }
        return candidates.min { a, b in
            distance(a.mac!, bssid) < distance(b.mac!, bssid)
        }
    }

    private func distance(_ a: MACAddress, _ b: MACAddress) -> UInt64 {
        a.value > b.value ? a.value - b.value : b.value - a.value
    }

    private func tile(_ title: String, _ value: String, sub: String? = nil, mono: Bool = false, subMono: Bool? = nil,
                      accent: Bool = false, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Group {
                if let action {
                    Button(action: action) { Text(value) }.buttonStyle(.plain)
                } else {
                    Text(value)
                }
            }
            .font(mono ? Theme.mono(12, weight: .semibold) : .system(size: 12, weight: .semibold))
            .foregroundStyle(accent ? Theme.accent : Theme.text)
            .lineLimit(1)
            if let sub {
                Text(sub).font(subMono ?? mono ? Theme.mono(11) : Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .modifier(WifiTileStyle())
    }

    private func tileColored(_ title: String, _ value: String, color: Color, sub: String?, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12, weight: .bold) : .system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            if let sub { Text(sub).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .modifier(WifiTileStyle())
    }

    private var roamTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("HEURE").frame(width: 60, alignment: .leading)
                Text("CHANGEMENT D’AP (AUJOURD’HUI)").frame(maxWidth: .infinity, alignment: .leading)
                Text("RSSI AVANT → APRÈS").frame(width: 160, alignment: .leading)
            }
            .font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panelMuted)
            ForEach(store.roams) { roam in
                HStack(spacing: 8) {
                    Text(WifiText.time(roam.time)).font(Theme.mono(12)).frame(width: 60, alignment: .leading)
                    Text("\(roam.from) → \(roam.to)").font(Theme.small).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(WifiQuality.dbm(roam.rssiBefore)) → \(WifiQuality.dbm(roam.rssiAfter))").font(Theme.mono(12))
                        .frame(width: 160, alignment: .leading)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

struct WifiTileStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Occupation des canaux

struct WifiChannelPanel: View {
    @ObservedObject var store: WifiStore

    var body: some View {
        let bandNetworks = store.networks.filter { $0.band == store.band }
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    WifiHeading("Occupation des canaux")
                    HStack(spacing: 2) {
                        ForEach(WifiBand.allCases) { band in
                            let selected = store.band == band
                            Button { store.band = band } label: {
                                HStack(spacing: 6) {
                                    Text(band.label).font(.system(size: 12, weight: .semibold))
                                    Text("\(store.networks.filter { $0.band == band }.count)")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                                }
                                .foregroundStyle(selected ? Theme.accentStrong : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.panel : .clear)
                                    .shadow(color: selected ? Color(hex: 0x0F172A, opacity: 0.12) : .clear, radius: 1, y: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.neutralSoft))
                    Spacer()
                    Text(summary(bandNetworks)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                if bandNetworks.isEmpty {
                    Text(store.networks.isEmpty ? "Cliquez sur «\u{00A0}Analyser\u{00A0}» pour voir l’occupation des canaux." : "Aucun réseau détecté en \(store.band.label).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 196)
                } else {
                    WifiChannelGraph(networks: bandNetworks, all: store.networks, band: store.band, selectedID: store.selectedID,
                                     noise: store.connected?.noise) { store.label(for: $0) }
                }
                if let selected = store.networks.first(where: { $0.id == store.selectedID }) {
                    selectedLine(selected)
                }
            }
        }
    }

    private func summary(_ list: [WifiNetwork]) -> String {
        guard !list.isEmpty else { return "Aucun réseau détecté" }
        var best: (WifiNetwork, Int)?
        for network in list {
            let count = list.filter { WifiChannelLayout.overlaps(network, $0) }.count
            if best == nil || count > best!.1 { best = (network, count) }
        }
        let width = store.band == .ghz24 ? "" : " (\(best!.0.widthMHz)\u{00A0}MHz)"
        return "\(list.count) réseaux · plus encombré\u{00A0}: canal \(best!.0.channel)\(width) · \(best!.1) réseaux"
    }

    private func selectedLine(_ network: WifiNetwork) -> some View {
        let overlapping = store.networks.filter { $0.id != network.id && WifiChannelLayout.overlaps(network, $0) }.count
        let pill: WifiPill
        if overlapping == 0 { pill = WifiPill(text: "Aucun chevauchement", foreground: Theme.success, background: Theme.successSoft) }
        else if overlapping >= 3 { pill = WifiPill(text: "\(overlapping) réseaux en chevauchement", foreground: Theme.warning, background: Theme.warningSoft) }
        else { pill = WifiPill(text: "\(overlapping) réseau\(overlapping > 1 ? "x" : "") en chevauchement") }
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(WifiText.color(of: network, in: store.networks)).frame(width: 10, height: 10)
            Text(store.label(for: network)).font(.system(size: 12, weight: .bold))
            Text("\(network.bssid?.formatted(.upperColon) ?? "BSSID masqué") · \(network.band.label) · canal \(network.channel) · \(network.widthMHz)\u{00A0}MHz · \(WifiQuality.dbm(network.rssi))\(network.standard.map { " · " + $0 } ?? "")")
                .font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
            Spacer()
            pill
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Réseaux visibles

struct WifiNetworksTable: View {
    @ObservedObject var store: WifiStore

    /// En-tête du tableau (style de TableHeader), avec le tri par RSSI.
    private var header: some View {
        HStack(spacing: 0) {
            headerCell("SSID", width: nil).padding(.leading, 4)
            headerCell("BSSID", width: 134)
            headerCell("Fabricant", width: 92)
            headerCell("Canal", width: 58, alignment: .trailing)
            headerCell("Largeur", width: 72, alignment: .trailing)
            headerCell("Bande", width: 64)
            Button { store.sortDescending.toggle() } label: {
                HStack(spacing: 3) {
                    Text("RSSI").font(Theme.captionSemibold).kerning(0.3)
                    Image(systemName: store.sortDescending ? "arrow.down" : "arrow.up").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.accentStrong)
                .padding(.horizontal, 8)
                .frame(width: 112, height: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Trier par RSSI")
            headerCell("Sécurité", width: 132)
        }
        .frame(height: 32)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func headerCell(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        let label = Text(title.uppercased()).font(Theme.captionSemibold).kerning(0.3).foregroundStyle(Theme.textSecondary)
            .lineLimit(1).padding(.horizontal, 8)
        if let width { label.frame(width: width, alignment: alignment) } else { label.frame(maxWidth: .infinity, alignment: alignment) }
    }

    var body: some View {
        let rows = self.rows
        let all = store.networks
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WifiHeading("Réseaux visibles")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    TextField("", text: $store.filter, prompt: Text("SSID, BSSID, fabricant…").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain).font(Theme.small)
                }
                .padding(.horizontal, 8)
                .frame(width: 170, height: 28)
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                chip(.all, "Toutes les bandes", all.count)
                chip(.band, "Bande \(store.band.label)", all.filter { $0.band == store.band }.count)
                chip(.flagged, "Signalés", all.filter(isFlagged).count)
                Spacer()
                Text("\(rows.count) affichés sur \(all.count)").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            header
            if rows.isEmpty {
                Text(all.isEmpty ? "Aucune analyse pour l’instant. L’analyse (balayage des canaux) ne se lance que sur demande."
                     : "Aucun réseau ne correspond à «\u{00A0}\(store.filter)\u{00A0}» avec ce filtre.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { network in row(network) }
                }
            }
            footer
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private func isFlagged(_ network: WifiNetwork) -> Bool {
        network.security.isOpen || network.security == .wep || (network.isHidden && !store.namesRedacted) || store.isSuspicious(network)
    }

    private var rows: [WifiNetwork] {
        let query = store.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.networks.filter { network in
            switch store.tableFilter {
            case .all: break
            case .band: if network.band != store.band { return false }
            case .flagged: if !isFlagged(network) { return false }
            }
            guard !query.isEmpty else { return true }
            let hay = [store.label(for: network), network.bssid?.formatted(.upperColon) ?? "", WifiText.vendor(network),
                       "canal \(network.channel)", network.security.label, network.standard ?? ""].joined(separator: " ").lowercased()
            return hay.contains(query)
        }
        .sorted { store.sortDescending ? $0.rssi > $1.rssi : $0.rssi < $1.rssi }
    }

    private func chip(_ filter: WifiTableFilter, _ label: String, _ count: Int) -> some View {
        let on = store.tableFilter == filter
        return Button { store.tableFilter = filter } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(on ? Theme.accentStrong : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(on ? Theme.accentSoft : Theme.panel))
            .overlay(Capsule().strokeBorder(on ? Theme.accent : Theme.border))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func row(_ network: WifiNetwork) -> some View {
        let selected = store.selectedID == network.id
        let colors = WifiText.qualityColor(network.rssi)
        let redacted = store.namesRedacted && network.isHidden
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(WifiText.color(of: network, in: store.networks)).frame(width: 9, height: 9)
                Text(store.label(for: network))
                    .font(network.isHidden ? Theme.small.italic() : .system(size: 12, weight: .semibold))
                    .foregroundStyle(network.isHidden ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                if network.isConnected { tag("CONNECTÉ", Theme.accentStrong, Color(hex: 0xDBEAFE)) }
                if network.isHidden && !redacted { tag("CACHÉ", Theme.warning, Theme.warningSoft) }
                if store.isSuspicious(network) { tag("NON AUTORISÉ\u{00A0}?", Theme.critical, Theme.criticalSoft) }
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(network.bssid?.formatted(.upperColon) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1)
                .padding(.horizontal, 8).frame(width: 134, alignment: .leading)
            Text(WifiText.vendor(network)).font(Theme.small).foregroundStyle(Theme.neutralText).lineLimit(1)
                .padding(.horizontal, 8).frame(width: 92, alignment: .leading)
            Text("\(network.channel)").font(Theme.mono(12, weight: .semibold))
                .padding(.horizontal, 8).frame(width: 58, alignment: .trailing)
            Text("\(network.widthMHz)\u{00A0}MHz").font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
                .padding(.horizontal, 8).frame(width: 72, alignment: .trailing)
            Text(network.band.label).font(Theme.small).foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 8).frame(width: 64, alignment: .leading)
            HStack(spacing: 6) {
                WifiSignalBar(rssi: network.rssi, width: 36)
                Text(WifiQuality.dbm(network.rssi)).font(Theme.mono(12, weight: .semibold)).foregroundStyle(colors.foreground)
            }
            .padding(.horizontal, 8).frame(width: 112, alignment: .leading)
            WifiPill.security(network.security)
                .padding(.horizontal, 8).frame(width: 132, alignment: .leading)
                .help(network.standard.map { "Norme\u{00A0}: \($0)" } ?? "Norme inconnue")
        }
        .frame(height: 28)
        .background(selected ? Theme.accentSoft : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.accent).frame(width: 3) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = network.id
            store.band = network.band
        }
    }

    private func tag(_ text: String, _ foreground: Color, _ background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
            .fixedSize()
    }

    private var footer: some View {
        let all = store.networks
        let ssids = Set(all.map { store.label(for: $0) }).count
        return HStack(spacing: 14) {
            (Text("\(all.count)").bold().foregroundStyle(Theme.text) + Text(" BSSID"))
            (Text("\(ssids)").bold().foregroundStyle(Theme.text) + Text(" SSID distincts"))
            (Text("\(all.filter { $0.security.isOpen }.count)").bold().foregroundStyle(Theme.critical) + Text(" ouvert(s)"))
            if !store.namesRedacted {
                (Text("\(all.filter(\.isHidden).count)").bold().foregroundStyle(Theme.warning) + Text(" caché(s)"))
            }
            (Text("\(all.filter(store.isSuspicious).count)").bold().foregroundStyle(Theme.critical) + Text(" non autorisé(s) possible(s)"))
            Spacer()
            Text(store.lastScan.map { "Analyse n°\u{00A0}\(store.scanCount) · \(WifiText.timeSeconds($0)) · \(store.connection?.interfaceName ?? "en0")" } ?? "Aucune analyse")
                .font(Theme.mono(12))
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Colonne latérale

struct WifiRecommendationsPanel: View {
    @ObservedObject var store: WifiStore

    var body: some View {
        let recos = store.recommendations
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading("Recommandations")
                    Text("\(recos.count)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.neutralText)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.neutralSoft))
                    Spacer()
                    if !store.dismissed.isEmpty {
                        Button("Rétablir (\(store.dismissed.count))") { store.dismissed = [] }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentStrong)
                    }
                }
                if recos.isEmpty {
                    Text(store.networks.isEmpty ? "Lancez une analyse pour obtenir des recommandations." :
                            (store.dismissed.isEmpty ? "Rien à signaler." : "Toutes les recommandations ont été ignorées."))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.vertical, 8)
                }
                ForEach(recos) { reco in card(reco) }
            }
        }
    }

    private func colors(_ severity: WifiRecommendation.Severity) -> (Color, Color, String) {
        switch severity {
        case .critique: return (Theme.critical, Theme.criticalSoft, "exclamationmark.octagon")
        case .alerte: return (Theme.warning, Theme.warningSoft, "exclamationmark.triangle")
        case .conseil: return (Theme.accentStrong, Color(hex: 0xDBEAFE), "lightbulb")
        case .info: return (Theme.neutralText, Theme.neutralSoft, "info.circle")
        }
    }

    private func card(_ reco: WifiRecommendation) -> some View {
        let (foreground, background, symbol) = colors(reco.severity)
        return HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(background)
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(foreground)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(reco.severity.label.uppercased())
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(foreground)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(background))
                    Text(reco.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.dismissed.insert(reco.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Ignorer\u{00A0}: \(reco.title)")
                }
                Text(reco.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if reco.networkID != nil || reco.band != nil {
                    Button(reco.networkID != nil ? "Voir le réseau" : "Voir la bande \(reco.band!.label)") { store.focus(reco) }
                        .buttonStyle(MiniButtonStyle())
                        .padding(.top, 3)
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Petit bouton secondaire (« mini » du croquis).
struct MiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Theme.neutralSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }
}

struct WifiHistoryPanel: View {
    @ObservedObject var store: WifiStore

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                WifiHeading("RSSI · 2 dernières minutes")
                if store.history.compactMap({ $0 }).isEmpty {
                    Text("Aucune mesure pour l’instant (relevé local toutes les 2\u{00A0}s).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    WifiHistoryChart(values: store.history, color: Theme.accent)
                    if let network = store.connection?.network {
                        let values = store.history.compactMap { $0 }
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 9, height: 9)
                            Text("\(store.label(for: network)) \(network.band.label.replacingOccurrences(of: "\u{00A0}GHz", with: "").replacingOccurrences(of: " GHz", with: ""))")
                                .font(Theme.small).lineLimit(1)
                            Spacer()
                            Text("min \(values.min() ?? 0) · max \(values.max() ?? 0)")
                                .font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                        }
                    }
                }
            }
        }
    }
}

struct WifiSurveyPanel: View {
    @ObservedObject var store: WifiStore
    @State private var room = ""

    var body: some View {
        let weak = store.surveyPoints.filter { $0.rssi < -70 }.count
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WifiHeading("Relevé de couverture")
                    Spacer()
                    WifiPill(text: store.surveyActive ? "Mode marche actif" : "Inactif",
                             foreground: store.surveyActive ? Theme.accentStrong : Theme.textSecondary,
                             background: store.surveyActive ? Color(hex: 0xDBEAFE) : Theme.neutralSoft)
                }
                if store.surveyActive, let network = store.connection?.network {
                    VStack(alignment: .leading, spacing: 6) {
                        (Text("Mesure en cours\u{00A0}: ") + Text(WifiQuality.dbm(network.rssi)).font(Theme.mono(12, weight: .bold))
                            .foregroundStyle(WifiText.qualityColor(network.rssi).foreground))
                            .font(Theme.small)
                        HStack(spacing: 6) {
                            TextField("", text: $room, prompt: Text("Nom du local (ex. Salle 210)").foregroundStyle(Theme.textTertiary))
                                .textFieldStyle(.plain).font(Theme.small)
                                .padding(.horizontal, 8).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                                .onSubmit(add)
                            Button("Noter", action: add).buttonStyle(MiniButtonStyle())
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    Text("Mode marche\u{00A0}: déplacez-vous de local en local et notez le RSSI de la connexion à chaque arrêt.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(store.surveyPoints) { point in
                        let colors = WifiText.qualityColor(point.rssi)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(point.room).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text("\(WifiText.time(point.time)) · BSSID …\(point.bssid.suffix(5))").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            WifiSignalBar(rssi: point.rssi, width: 50)
                            Text(WifiQuality.dbm(point.rssi)).font(Theme.mono(12, weight: .semibold)).frame(width: 64, alignment: .trailing)
                            Text(WifiQuality(rssi: point.rssi).label).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.foreground)
                                .frame(width: 46).padding(.vertical, 1).background(Capsule().fill(colors.background))
                            Button { store.surveyPoints.removeAll { $0.id == point.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Retirer le point \(point.room)")
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
                HStack {
                    Text("\(store.surveyPoints.count) point\(store.surveyPoints.count > 1 ? "s" : "") mesuré\(store.surveyPoints.count > 1 ? "s" : "") · \(weak) faible\(weak > 1 ? "s" : "") (sous \u{2212}70\u{00A0}dBm)")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.top, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }

    private func add() {
        store.addSurveyPoint(room: room)
        room = ""
    }
}
