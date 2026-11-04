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

    /// En-tête : sur une ligne quand la place suffit ; sinon la qualité et le bouton passent dessous.
    private func header(_ network: WifiNetwork) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identity(network)
                Spacer(minLength: 12)
                qualityAndAction(network)
            }
            VStack(alignment: .leading, spacing: 10) {
                identity(network)
                HStack(spacing: 10) {
                    qualityAndAction(network)
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        WifiHeading("Connexion actuelle")
                        Text(store.label(for: network)).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    }
                }
                SwitchFlowLayout(spacing: 8) { pills(network) }
                qualityAndAction(network)
            }
        }
    }

    private func identity(_ network: WifiNetwork) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                WifiHeading("Connexion actuelle")
                HStack(spacing: 8) {
                    Text(store.label(for: network)).font(.system(size: 16, weight: .bold)).lineLimit(1).fixedSize()
                    pills(network)
                }
            }
        }
    }

    @ViewBuilder private func pills(_ network: WifiNetwork) -> some View {
        WifiPill(text: "Connecté", foreground: Theme.success, background: Theme.successSoft)
        if let standard = network.standard { WifiPill(text: WifiConnectionPanel.generation(standard)) }
    }

    private func qualityAndAction(_ network: WifiNetwork) -> some View {
        let quality = WifiQuality(rssi: network.rssi)
        let colors = WifiText.qualityColor(network.rssi)
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Qualité").font(Theme.small).foregroundStyle(Theme.textSecondary)
                WifiSignalBar(rssi: network.rssi, width: 120, height: 8)
                Text(quality.longLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.foreground)
            }
            if let me = myDevice {
                Button("Fiche de ce Mac") { state.showDevice(me.id) }.buttonStyle(.secondary)
            }
        }
        .fixedSize()
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
            if let secondary = guidance.secondaryButtonTitle {
                Button(secondary) { store.requestLocationSecondary() }
                    .buttonStyle(.secondary)
            }
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
            tile("SNR", network.snr.map { "\($0)\u{00A0}dB" } ?? "—", sub: "Excellent dès 25\u{00A0}dB", mono: true, subMono: false)
            tile("Débit PHY", connection.transmitRate.flatMap(\.finiteOrNil).map { "\($0.rounded(.towardZero).clampedInt)\u{00A0}Mb/s" } ?? "—", sub: network.standard.map(WifiConnectionPanel.generation), mono: true, subMono: false)
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
        let candidates = InvModel.shared.withManualTypes(state.devices).filter { $0.deviceType == .pointAcces && $0.mac?.ouiValue == bssid.ouiValue }
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
        WifiRoamTable(roams: store.roams)
    }
}

/// Historique d'itinérance (changements d'AP depuis l'ouverture) : tableau standard (note 8,
/// clé « wifi.itinerance »).
struct WifiRoamTable: View {
    let roams: [WifiStore.Roam]
    @StateObject private var table = StandardTableModel<WifiStore.Roam>(id: "wifi.itinerance", columns: Self.columns,
                                                                        sortKeys: Self.sortKeys, defaultSort: "heure")

    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "ancien", title: "Ancien AP"),
        StandardColumn(id: "nouveau", title: "Nouvel AP"),
        StandardColumn(id: "rssi", title: "RSSI avant → après"),
        StandardColumn(id: "ecart", title: "Écart de signal", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WifiStore.Roam>] = [
        "heure": KeyPathComparator(\WifiStore.Roam.time),
        "ancien": KeyPathComparator(\WifiStore.Roam.from),
        "nouveau": KeyPathComparator(\WifiStore.Roam.to),
        "rssi": KeyPathComparator(\WifiStore.Roam.rssiAfter),
        "ecart": KeyPathComparator(\WifiStore.Roam.rssiGain),
    ]

    var body: some View {
        let rows = roams.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WifiHeading("Changements d’AP (aujourd’hui)")
                Spacer()
                StandardColumnsMenu(model: table)
            }
            Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("HEURE", sortUsing: table.sort("heure")) { roam in
                    WifiCell(WifiText.time(roam.time), mono: 12, color: Theme.text)
                }
                .width(min: 44, ideal: 54)
                .customizationID("heure")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ANCIEN AP", sortUsing: table.sort("ancien")) { roam in WifiCell(roam.from).help(roam.from) }
                    .width(min: 100, ideal: 260)
                    .customizationID("ancien")

                TableColumn("NOUVEL AP", sortUsing: table.sort("nouveau")) { roam in WifiCell(roam.to).help(roam.to) }
                    .width(min: 100, ideal: 260)
                    .customizationID("nouveau")

                TableColumn("RSSI AVANT → APRÈS", sortUsing: table.sort("rssi")) { roam in
                    (Text(WifiQuality.dbm(roam.rssiBefore)).foregroundStyle(WifiText.qualityColor(roam.rssiBefore).foreground)
                        + Text(" → ").foregroundStyle(Theme.textSecondary)
                        + Text(WifiQuality.dbm(roam.rssiAfter)).foregroundStyle(WifiText.qualityColor(roam.rssiAfter).foreground))
                        .font(Theme.mono(12))
                        .lineLimit(1)
                        .frame(height: 20)
                }
                .width(min: 120, ideal: 150)
                .customizationID("rssi")

                TableColumn("ÉCART", sortUsing: table.sort("ecart")) { roam in
                    WifiCell(roam.rssiGain > 0 ? "+\(roam.rssiGain)\u{00A0}dB" : "\(roam.rssiGain)\u{00A0}dB", mono: 12,
                             color: roam.rssiGain >= 0 ? Theme.success : Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 64)
                .customizationID("ecart")
                .defaultVisibility(.hidden)
            }
            .standardTableStyle()
            .frame(height: 36 + CGFloat(rows.count) * 28 + 8)
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        }
    }
}

extension WifiStore.Roam {
    /// Gain de signal du changement d'AP (dB, positif : meilleur signal après).
    var rssiGain: Int { rssiAfter - rssiBefore }
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
                // Petite fenêtre : le résumé passe sous le titre et le choix de bande.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        WifiHeading("Occupation des canaux").fixedSize()
                        bandPicker
                        Spacer(minLength: 8)
                        Text(summary(bandNetworks)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            WifiHeading("Occupation des canaux").fixedSize()
                            bandPicker
                            Spacer(minLength: 0)
                        }
                        Text(summary(bandNetworks)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    /// Choix de la bande : contrôle segmenté natif (nombre de réseaux de chaque bande).
    private var bandPicker: some View {
        Picker("Bande", selection: $store.band) {
            ForEach(WifiBand.allCases) { band in
                Text("\(band.label) (\(store.networks.filter { $0.band == band }.count))").tag(band)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
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
        let name = HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(WifiText.color(of: network, in: store.networks)).frame(width: 10, height: 10)
            Text(store.label(for: network)).font(.system(size: 12, weight: .bold)).lineLimit(1).fixedSize()
        }
        let details = Text("\(network.bssid?.formatted(.upperColon) ?? "BSSID masqué") · \(network.band.label) · canal \(network.channel) · \(network.widthMHz)\u{00A0}MHz · \(WifiQuality.dbm(network.rssi))\(network.standard.map { " · " + $0 } ?? "")")
            .font(Theme.mono(12)).foregroundStyle(Theme.neutralText).lineLimit(1)
        // Petite fenêtre : les détails passent sous le nom au lieu d'être coupés.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name
                details.fixedSize()
                Spacer(minLength: 8)
                pill
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    pill
                }
                details.truncationMode(.middle).padding(.leading, 18)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Réseaux visibles

/// Ligne du tableau des réseaux : le réseau, son nom affiché et ses clés de tri.
struct WifiNetworkRow: Identifiable {
    let network: WifiNetwork
    /// Nom affiché (« (nom masqué par macOS) » quand macOS le cache).
    let label: String
    let vendor: String
    let isSuspicious: Bool
    /// SSID caché que macOS ne masque pas (badge « CACHÉ »).
    let showsHidden: Bool

    var id: String { network.id }

    /// Les valeurs absentes vont en fin de liste en tri croissant.
    private static let last = "\u{10FFFF}"
    var ssidSort: String { network.isHidden ? Self.last : label.lowercased() }
    var bssidSort: UInt64 { network.bssid?.value ?? UInt64.max }
    var vendorSort: String { vendor == "—" ? Self.last : vendor.lowercased() }
    var channel: Int { network.channel }
    var width: Int { network.widthMHz }
    var bandSort: Int { WifiBand.allCases.firstIndex(of: network.band) ?? 0 }
    var rssi: Int { network.rssi }
    var securitySort: String { network.security.label }
    var noiseSort: Int { network.noise ?? Int.max }
    var snrSort: Int { network.snr ?? Int.min }
    var standardSort: String { network.standard ?? Self.last }
    var oui: String { network.bssid.map { String($0.formatted(.upperColon).prefix(8)) } ?? "—" }
    var ouiSort: String { network.bssid == nil ? Self.last : oui }

    /// État : connecté, non autorisé possible, caché.
    var state: String {
        var parts: [String] = []
        if network.isConnected { parts.append("Connecté") }
        if isSuspicious { parts.append("Non autorisé\u{00A0}?") }
        if showsHidden { parts.append("Caché") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
    var stateSort: Int { network.isConnected ? 0 : (isSuspicious ? 1 : (showsHidden ? 2 : 3)) }
}

/// Réseaux visibles : tableau standard (note 8, clé « wifi.reseaux »), filtres du croquis au-dessus.
struct WifiNetworksTable: View {
    @ObservedObject var store: WifiStore
    @StateObject private var table = WifiNetworksTable.makeModel()

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ssid", title: "SSID", isRequired: true),
        StandardColumn(id: "bssid", title: "BSSID"),
        StandardColumn(id: "fabricant", title: "Fabricant"),
        StandardColumn(id: "canal", title: "Canal"),
        StandardColumn(id: "largeur", title: "Largeur"),
        StandardColumn(id: "bande", title: "Bande"),
        StandardColumn(id: "rssi", title: "RSSI"),
        StandardColumn(id: "securite", title: "Sécurité"),
        StandardColumn(id: "bruit", title: "Bruit", isDefaultVisible: false),
        StandardColumn(id: "snr", title: "SNR", isDefaultVisible: false),
        StandardColumn(id: "norme", title: "Norme (mode PHY)", isDefaultVisible: false),
        StandardColumn(id: "oui", title: "OUI du BSSID", isDefaultVisible: false),
        StandardColumn(id: "etat", title: "État", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WifiNetworkRow>] = [
        "ssid": KeyPathComparator(\WifiNetworkRow.ssidSort),
        "bssid": KeyPathComparator(\WifiNetworkRow.bssidSort),
        "fabricant": KeyPathComparator(\WifiNetworkRow.vendorSort),
        "canal": KeyPathComparator(\WifiNetworkRow.channel),
        "largeur": KeyPathComparator(\WifiNetworkRow.width),
        "bande": KeyPathComparator(\WifiNetworkRow.bandSort),
        "rssi": KeyPathComparator(\WifiNetworkRow.rssi),
        "securite": KeyPathComparator(\WifiNetworkRow.securitySort),
        "bruit": KeyPathComparator(\WifiNetworkRow.noiseSort),
        "snr": KeyPathComparator(\WifiNetworkRow.snrSort),
        "norme": KeyPathComparator(\WifiNetworkRow.standardSort),
        "oui": KeyPathComparator(\WifiNetworkRow.ouiSort),
        "etat": KeyPathComparator(\WifiNetworkRow.stateSort),
    ]

    /// Tri du croquis au premier lancement : RSSI décroissant (signal le plus fort en haut).
    @MainActor
    static func makeModel() -> StandardTableModel<WifiNetworkRow> {
        StandardTableModel(id: "wifi.reseaux", columns: columns, sortKeys: sortKeys, defaultSort: "rssi",
                           defaultAscending: false)
    }

    /// Hauteur d'une ligne du tableau (contenu de 20 points et marges du tableau).
    private static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 36

    var body: some View {
        let rows = self.rows
        let all = store.networks
        VStack(spacing: 0) {
            // Moins de place : libellés courts du filtre, puis la recherche et le filtre sur deux lignes.
            ViewThatFits(in: .horizontal) {
                ForEach([false, true], id: \.self) { short in
                    HStack(spacing: 8) {
                        WifiHeading("Réseaux visibles").fixedSize()
                        searchField
                        filterPicker(all, short: short)
                        Spacer(minLength: 4)
                        // Le nombre de réseaux affichés passe dans le pied pour laisser la place au bouton « Colonnes ».
                        StandardColumnsMenu(model: table)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        WifiHeading("Réseaux visibles").fixedSize()
                        searchField
                        Spacer(minLength: 4)
                        StandardColumnsMenu(model: table)
                    }
                    filterPicker(all)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            if rows.isEmpty {
                Text(all.isEmpty ? "Aucune analyse pour l’instant. L’analyse (balayage des canaux) ne se lance que sur demande."
                     : "Aucun réseau ne correspond à «\u{00A0}\(store.filter)\u{00A0}» avec ce filtre.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                tableView(rows)
                    // Le tableau défile seul : sa hauteur suit le nombre de lignes (l'écran défile déjà).
                    .frame(height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight + 8)
            }
            footer(shown: rows.count)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private func tableView(_ rows: [WifiNetworkRow]) -> some View {
        let selection = Binding<String?>(
            get: { store.selectedID },
            set: { id in
                store.selectedID = id
                if let network = store.networks.first(where: { $0.id == id }) { store.band = network.band }
            })
        return Table(rows, selection: selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("SSID", sortUsing: table.sort("ssid")) { row in ssidCell(row) }
                    .width(min: 100, ideal: 124)
                    .customizationID("ssid")
                    .disabledCustomizationBehavior(.visibility)

                TableColumn("BSSID", sortUsing: table.sort("bssid")) { row in
                    WifiCell(row.network.bssid?.formatted(.upperColon) ?? "—", mono: 11, dimmed: row.network.bssid == nil)
                }
                .width(min: 100, ideal: 116)
                .customizationID("bssid")

                TableColumn("FABRICANT", sortUsing: table.sort("fabricant")) { row in WifiCell(row.vendor, dimmed: row.vendor == "—") }
                    .width(min: 56, ideal: 74)
                    .customizationID("fabricant")

                TableColumn("CANAL", sortUsing: table.sort("canal")) { row in
                    WifiCell("\(row.channel)", mono: 12, weight: .semibold, color: Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 44, ideal: 54)
                .customizationID("canal")

                TableColumn("LARGEUR", sortUsing: table.sort("largeur")) { row in
                    WifiCell("\(row.width)\u{00A0}MHz", mono: 12).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 64)
                .customizationID("largeur")

                TableColumn("BANDE", sortUsing: table.sort("bande")) { row in WifiCell(row.network.band.label) }
                    .width(min: 44, ideal: 48)
                    .customizationID("bande")

                TableColumn("RSSI", sortUsing: table.sort("rssi")) { row in
                    HStack(spacing: 6) {
                        WifiSignalBar(rssi: row.rssi, width: 28)
                        Text(WifiQuality.dbm(row.rssi)).font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(WifiText.qualityColor(row.rssi).foreground)
                            .lineLimit(1)
                    }
                    .frame(height: 20)
                }
                .width(min: 80, ideal: 86)
                .customizationID("rssi")

                TableColumn("SÉCURITÉ", sortUsing: table.sort("securite")) { row in
                    WifiPill.security(row.network.security)
                        .help(row.network.standard.map { "Norme\u{00A0}: \($0)" } ?? "Norme inconnue")
                }
                .width(min: 80, ideal: 104)
                .customizationID("securite")
            }

            Group {
                TableColumn("BRUIT", sortUsing: table.sort("bruit")) { row in
                    WifiCell(row.network.noise.map(WifiQuality.dbm) ?? "—", mono: 12, dimmed: row.network.noise == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 72)
                .customizationID("bruit")
                .defaultVisibility(.hidden)

                TableColumn("SNR", sortUsing: table.sort("snr")) { row in
                    WifiCell(row.network.snr.map { "\($0)\u{00A0}dB" } ?? "—", mono: 12, dimmed: row.network.snr == nil)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 46, ideal: 56)
                .customizationID("snr")
                .defaultVisibility(.hidden)

                TableColumn("NORME", sortUsing: table.sort("norme")) { row in
                    WifiCell(row.network.standard ?? "—", mono: 12, dimmed: row.network.standard == nil)
                }
                .width(min: 60, ideal: 80)
                .customizationID("norme")
                .defaultVisibility(.hidden)

                TableColumn("OUI", sortUsing: table.sort("oui")) { row in
                    WifiCell(row.oui, mono: 11, dimmed: row.network.bssid == nil)
                }
                .width(min: 60, ideal: 72)
                .customizationID("oui")
                .defaultVisibility(.hidden)

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    WifiCell(row.state, dimmed: row.state == "—")
                }
                .width(min: 60, ideal: 110)
                .customizationID("etat")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
    }

    /// SSID et badges ; quand la colonne est trop étroite pour le nom entier et ses badges, les
    /// badges deviennent des pastilles (libellé en infobulle) pour laisser le nom lisible.
    private func ssidCell(_ row: WifiNetworkRow) -> some View {
        let network = row.network
        let badges = ssidBadges(row)
        let label = Text(row.label)
            .font(network.isHidden ? Theme.small.italic() : .system(size: 12, weight: .semibold))
            .foregroundStyle(network.isHidden ? Theme.textSecondary : Theme.text)
            .lineLimit(1)
        let square = RoundedRectangle(cornerRadius: 2).fill(WifiText.color(of: network, in: store.networks)).frame(width: 9, height: 9)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                square
                label.fixedSize()
                ForEach(badges, id: \.text) { badge in tag(badge.text, badge.foreground, badge.background) }
            }
            HStack(spacing: 5) {
                square
                label.truncationMode(.tail)
                ForEach(badges, id: \.text) { badge in
                    Circle().fill(badge.foreground).frame(width: 7, height: 7).help(badge.text)
                }
            }
        }
        .frame(height: 20)
        .help(([row.label] + badges.map(\.text)).joined(separator: " · "))
    }

    private func ssidBadges(_ row: WifiNetworkRow) -> [(text: String, foreground: Color, background: Color)] {
        var badges: [(text: String, foreground: Color, background: Color)] = []
        if row.network.isConnected { badges.append(("CONNECTÉ", Theme.accentStrong, Color(light: 0xDBEAFE, dark: 0x1B3250))) }
        if row.showsHidden { badges.append(("CACHÉ", Theme.warning, Theme.warningSoft)) }
        if row.isSuspicious { badges.append(("NON AUTORISÉ\u{00A0}?", Theme.critical, Theme.criticalSoft)) }
        return badges
    }

    private func isFlagged(_ network: WifiNetwork) -> Bool {
        network.security.isOpen || network.security == .wep || (network.isHidden && !store.namesRedacted) || store.isSuspicious(network)
    }

    private var rows: [WifiNetworkRow] {
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
        .map { network in
            WifiNetworkRow(network: network, label: store.label(for: network), vendor: WifiText.vendor(network),
                           isSuspicious: store.isSuspicious(network),
                           showsHidden: network.isHidden && !store.namesRedacted)
        }
        // Tri du tableau, puis BSSID pour départager (ordre stable d'une analyse à l'autre).
        .sorted(using: table.sortOrder + [KeyPathComparator(\WifiNetworkRow.bssidSort)])
    }

    /// Champ de recherche natif du tableau.
    private var searchField: some View {
        TextField("Filtrer les réseaux", text: $store.filter, prompt: Text("SSID, BSSID, fabricant…"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(Theme.small)
            .frame(minWidth: 110, idealWidth: 140, maxWidth: 170)
    }

    /// Filtre des réseaux : contrôle segmenté natif (nombre de réseaux de chaque filtre).
    /// `short` : « Toutes » et « 2,4 GHz » au lieu de « Toutes les bandes » et « Bande 2,4 GHz ».
    private func filterPicker(_ all: [WifiNetwork], short: Bool = false) -> some View {
        Picker("Réseaux affichés", selection: $store.tableFilter) {
            Text("\(short ? "Toutes" : "Toutes les bandes") (\(all.count))").tag(WifiTableFilter.all)
            Text("\(short ? "" : "Bande ")\(store.band.label) (\(all.filter { $0.band == store.band }.count))").tag(WifiTableFilter.band)
            Text("Signalés (\(all.filter(isFlagged).count))").tag(WifiTableFilter.flagged)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func tag(_ text: String, _ foreground: Color, _ background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
            .fixedSize()
    }

    /// Pied : totaux de l'analyse ; « 9 affichés sur 15 BSSID » quand un filtre masque des réseaux.
    private func footer(shown: Int) -> some View {
        let all = store.networks
        let ssids = Set(all.map { store.label(for: $0) }).count
        // Petite fenêtre : les totaux passent à la ligne au lieu d'être coupés.
        return SwitchFlowLayout(spacing: 14, lineSpacing: 4) {
            if shown < all.count {
                (Text("\(shown)").bold().foregroundStyle(Theme.text) + Text(" affichés sur ")
                    + Text("\(all.count)").bold().foregroundStyle(Theme.text) + Text(" BSSID"))
            } else {
                (Text("\(all.count)").bold().foregroundStyle(Theme.text) + Text(" BSSID"))
            }
            (Text("\(ssids)").bold().foregroundStyle(Theme.text) + Text(" SSID distincts"))
            (Text("\(all.filter { $0.security.isOpen }.count)").bold().foregroundStyle(Theme.critical) + Text(" ouvert(s)"))
            if !store.namesRedacted {
                (Text("\(all.filter(\.isHidden).count)").bold().foregroundStyle(Theme.warning) + Text(" caché(s)"))
            }
            (Text("\(all.filter(store.isSuspicious).count)").bold().foregroundStyle(Theme.critical) + Text(" non autorisé(s) possible(s)"))
            Text(store.lastScan.map { "Analyse n°\u{00A0}\(store.scanCount) · \(WifiText.timeSeconds($0)) · \(store.connection?.interfaceName ?? "en0")" } ?? "Aucune analyse")
                .font(Theme.mono(12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Texte d'une cellule des tableaux Wi-Fi.
struct WifiCell: View {
    let text: String
    /// Taille de la police à chasse fixe ; nil : police du texte courant.
    var mono: CGFloat?
    var weight: Font.Weight = .regular
    var color: Color = Theme.neutralText
    var dimmed = false

    init(_ text: String, mono: CGFloat? = nil, weight: Font.Weight = .regular, color: Color = Theme.neutralText, dimmed: Bool = false) {
        self.text = text
        self.mono = mono
        self.weight = weight
        self.color = color
        self.dimmed = dimmed
    }

    var body: some View {
        Text(text)
            .font(mono.map { Theme.mono($0, weight: weight) } ?? Theme.small)
            .foregroundStyle(dimmed ? Theme.textTertiary : color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 20)
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
        case .conseil: return (Theme.accentStrong, Color(light: 0xDBEAFE, dark: 0x1B3250), "lightbulb")
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
                // Badge sur sa propre ligne : le titre prend toute la largeur de la carte.
                HStack(alignment: .center, spacing: 6) {
                    Text(reco.severity.label.uppercased())
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(foreground)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(background))
                    Spacer(minLength: 0)
                    Button { store.dismissed.insert(reco.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Ignorer\u{00A0}: \(reco.title)")
                }
                Text(reco.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(reco.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if reco.networkID != nil || reco.band != nil {
                    Button(reco.networkID != nil ? "Voir le réseau" : "Voir la bande \(reco.band!.label)") { store.focus(reco) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
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
                             background: store.surveyActive ? Color(light: 0xDBEAFE, dark: 0x1B3250) : Theme.neutralSoft)
                }
                if store.surveyActive, let network = store.connection?.network {
                    VStack(alignment: .leading, spacing: 6) {
                        (Text("Mesure en cours\u{00A0}: ") + Text(WifiQuality.dbm(network.rssi)).font(Theme.mono(12, weight: .bold))
                            .foregroundStyle(WifiText.qualityColor(network.rssi).foreground))
                            .font(Theme.small)
                        HStack(spacing: 6) {
                            TextField("Nom du local", text: $room, prompt: Text("Nom du local (ex. Salle 210)"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder).font(Theme.small)
                                .onSubmit(add)
                            Button("Noter", action: add).buttonStyle(.bordered)

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
