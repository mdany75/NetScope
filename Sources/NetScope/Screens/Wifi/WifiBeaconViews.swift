import NetScopeCore
import SwiftUI

// Note 71 : éléments des balises dans l'analyseur Wi-Fi (ce Mac) : cellules du tableau des réseaux
// et panneau de détail du BSSID sélectionné.

enum WifiBeaconText {
    /// Génération : d'après la balise, sinon d'après la norme lue par CoreWLAN.
    static func generation(_ network: WifiNetwork) -> WifiGeneration? {
        if let beacon = network.beacon { return beacon.generation(band: network.band) }
        guard let standard = network.standard else { return nil }
        let generation = WifiGeneration.from(standard: standard)
        return generation == .wifi6 && network.band == .ghz6 ? .wifi6E : generation
    }

    /// Couleur de la charge : saturée au-delà du seuil, à surveiller dès 50 %.
    static func loadColor(_ percent: Int) -> (foreground: Color, background: Color) {
        if percent > WifiBeaconAdvisor.utilizationThreshold { return (Theme.critical, Theme.criticalSoft) }
        if percent >= 50 { return (Theme.warning, Theme.warningSoft) }
        return (Theme.success, Theme.successSoft)
    }

    static func clientsColor(_ count: Int) -> Color {
        count > WifiBeaconAdvisor.clientThreshold ? Theme.critical : Theme.neutralText
    }

    static func yesNo(_ value: Bool) -> String { value ? "Oui" : "Non" }

    static func roamingHelp(_ beacon: WifiBeaconInfo) -> String {
        "802.11k (voisines)\u{00A0}: \(yesNo(beacon.supports11k).lowercased()) · 802.11v (transition guidée)\u{00A0}: \(yesNo(beacon.supports11v).lowercased()) · 802.11r (transition rapide)\u{00A0}: \(yesNo(beacon.supports11r).lowercased())"
    }
}

/// Trois pastilles « k v r » : pleines si la fonction est annoncée, estompées sinon.
struct WifiRoamingBadges: View {
    let beacon: WifiBeaconInfo

    var body: some View {
        HStack(spacing: 3) {
            badge("k", beacon.supports11k)
            badge("v", beacon.supports11v)
            badge("r", beacon.supports11r)
        }
        .frame(height: 20)
        .help(WifiBeaconText.roamingHelp(beacon))
        .accessibilityLabel(WifiBeaconText.roamingHelp(beacon))
    }

    private func badge(_ letter: String, _ on: Bool) -> some View {
        Text(letter)
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(on ? Theme.success : Theme.textTertiary)
            .strikethrough(!on, color: Theme.textTertiary)
            .frame(width: 17, height: 16)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(on ? Theme.successSoft : Theme.neutralSoft))
    }
}

/// Utilisation du canal : petite barre et pourcentage.
struct WifiLoadCell: View {
    let load: WifiBSSLoad
    var barWidth: CGFloat = 30

    var body: some View {
        let percent = load.utilizationPercent
        let colors = WifiBeaconText.loadColor(percent)
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.border)
                RoundedRectangle(cornerRadius: 3).fill(colors.foreground)
                    .frame(width: barWidth * CGFloat(max(4, percent)) / 100)
            }
            .frame(width: barWidth, height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("\(percent)\u{00A0}%").font(Theme.mono(12, weight: .semibold)).foregroundStyle(colors.foreground).lineLimit(1)
        }
        .frame(height: 20)
        .help("Utilisation du canal vue par la borne\u{00A0}: \(percent)\u{00A0}% · \(load.stationCount) client\(load.stationCount > 1 ? "s" : "") associé\(load.stationCount > 1 ? "s" : "")")
    }
}

// MARK: - Panneau de détail

/// Détail des éléments de la balise du BSSID sélectionné (itinérance, charge, radio, sécurité, borne).
struct WifiBeaconPanel: View {
    @ObservedObject var store: WifiStore

    var body: some View {
        if let network = store.networks.first(where: { $0.id == store.selectedID }) {
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    header(network)
                    if let beacon = network.beacon {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                            roamingSection(beacon)
                            loadSection(beacon)
                            radioSection(network, beacon)
                            securitySection(beacon)
                            apSection(network, beacon)
                        }
                        if beacon.isTruncated {
                            Label("Balise incomplète\u{00A0}: certains éléments étaient tronqués et ont été ignorés.", systemImage: "exclamationmark.triangle")
                                .font(Theme.small).foregroundStyle(Theme.warning)
                        }
                    } else {
                        missing(network)
                    }
                }
            }
        }
    }

    private func header(_ network: WifiNetwork) -> some View {
        let title = HStack(spacing: 8) {
            WifiHeading("Balise du BSSID").fixedSize()
            RoundedRectangle(cornerRadius: 3).fill(WifiText.color(of: network, in: store.networks)).frame(width: 10, height: 10)
            Text(store.label(for: network)).font(.system(size: 12, weight: .bold)).lineLimit(1).fixedSize()
            Text(network.bssid?.formatted(.upperColon) ?? "BSSID masqué").font(Theme.mono(12)).foregroundStyle(Theme.neutralText)
                .lineLimit(1).truncationMode(.middle)
        }
        let pills = HStack(spacing: 6) {
            if let generation = WifiBeaconText.generation(network), generation >= .wifi4 {
                WifiPill(text: generation.label)
            }
            if let security = network.beacon?.security ?? (network.security == .unknown ? nil : network.security) {
                WifiPill.security(security)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                pills
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                pills
            }
        }
    }

    /// Sans balise : la localisation manque (BSSID masqué) ou macOS n'a rien fourni.
    @ViewBuilder private func missing(_ network: WifiNetwork) -> some View {
        let masked = network.bssid == nil || !store.locationAuthorized
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: masked ? "location.slash" : "questionmark.circle")
                .foregroundStyle(masked ? Theme.warning : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(masked ? "Éléments de la balise masqués par macOS" : "Aucun élément de balise pour ce BSSID")
                    .font(Theme.bodySemibold)
                Text(masked
                     ? "Comme le BSSID, les éléments des balises (802.11k/v/r, charge, sécurité détaillée) ne sont fournis qu’avec l’autorisation de localisation."
                     : "macOS n’a pas transmis les éléments de cette balise (réseau ajouté depuis la connexion actuelle). Relancez une analyse.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if masked {
                Button(store.locationGuidance.buttonTitle) { store.requestLocation() }
                    .buttonStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(masked ? Theme.warningSoft : Theme.panelMuted))
    }

    // MARK: Sections

    private func roamingSection(_ beacon: WifiBeaconInfo) -> some View {
        section("Itinérance", symbol: "arrow.triangle.swap") {
            flag("802.11k · voisines", beacon.supports11k,
                 detail: beacon.radioMeasurement && !beacon.neighborReport ? "mesures radio sans Neighbor Report" : nil)
            flag("802.11v · transition guidée", beacon.supports11v)
            flag("802.11r · transition rapide", beacon.supports11r,
                 detail: beacon.mobilityDomain.map { "domaine \($0.mdidText) · \($0.overDS ? "par le DS" : "par les airs")" })
        }
    }

    @ViewBuilder private func loadSection(_ beacon: WifiBeaconInfo) -> some View {
        section("Charge (QBSS)", symbol: "person.3") {
            if let load = beacon.bssLoad {
                let colors = WifiBeaconText.loadColor(load.utilizationPercent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Utilisation du canal").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 6)
                        Text("\(load.utilizationPercent)\u{00A0}%").font(Theme.mono(12, weight: .bold)).foregroundStyle(colors.foreground)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.border)
                            RoundedRectangle(cornerRadius: 3).fill(colors.foreground)
                                .frame(width: proxy.size.width * CGFloat(max(2, load.utilizationPercent)) / 100)
                            Rectangle().fill(Theme.textTertiary)
                                .frame(width: 1)
                                .offset(x: proxy.size.width * CGFloat(WifiBeaconAdvisor.utilizationThreshold) / 100)
                                .help("Seuil de saturation\u{00A0}: \(WifiBeaconAdvisor.utilizationThreshold)\u{00A0}%")
                        }
                    }
                    .frame(height: 6)
                }
                row("Clients associés", "\(load.stationCount)", color: WifiBeaconText.clientsColor(load.stationCount))
                // Unités de 32 µs par seconde : 31 250 = tout le temps d'antenne.
                if let capacity = load.availableCapacity, capacity > 0 {
                    row("Capacité d’admission libre", "\(min(100, capacity * 32 / 10_000))\u{00A0}%")
                }
                if WifiBeaconAdvisor.isSaturated(load) {
                    Text("Borne saturée (seuils\u{00A0}: \(WifiBeaconAdvisor.utilizationThreshold)\u{00A0}% ou \(WifiBeaconAdvisor.clientThreshold) clients)")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Élément BSS Load non annoncé par la borne.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func radioSection(_ network: WifiNetwork, _ beacon: WifiBeaconInfo) -> some View {
        let generation = beacon.generation(band: network.band)
        let amendments = [beacon.hasHT ? "HT" : nil, beacon.hasVHT ? "VHT" : nil, beacon.hasHE ? "HE" : nil, beacon.hasEHT ? "EHT" : nil]
            .compactMap { $0 }
        return section("Radio", symbol: "antenna.radiowaves.left.and.right") {
            row("Génération", generation == .legacy ? "802.11a/b/g" : "\(generation.label) (\(generation.standard))")
            row("Éléments", amendments.isEmpty ? "—" : amendments.joined(separator: " · "))
            row("Largeur annoncée", beacon.channelWidthMHz.map { "\($0)\u{00A0}MHz" } ?? "20\u{00A0}MHz")
            row("Flux spatiaux", beacon.spatialStreams.map { "\($0)×\($0)" } ?? "—")
            row("DTIM · pays", "\(beacon.dtimPeriod.map(String.init) ?? "—") · \(beacon.countryCode ?? "—")")
        }
    }

    private func securitySection(_ beacon: WifiBeaconInfo) -> some View {
        section("Sécurité (RSN)", symbol: "lock") {
            if let rsn = beacon.rsn ?? beacon.wpa {
                row("Mode", beacon.security?.label ?? "—", color: beacon.security?.isWPA3 == true ? Theme.success : Theme.text)
                row("Authentification", rsn.akmLabels.isEmpty ? "—" : rsn.akmLabels.joined(separator: ", "))
                row("Chiffrement", rsn.pairwiseLabels.isEmpty ? "—" : rsn.pairwiseLabels.joined(separator: ", "))
                row("PMF (802.11w)", beacon.pmf.label,
                    color: beacon.pmf == .required ? Theme.success : (beacon.pmf == .absent ? Theme.warning : Theme.text))
                if beacon.wpa != nil, beacon.rsn != nil {
                    Text("Ancien WPA (TKIP) encore annoncé en parallèle.").font(Theme.caption).foregroundStyle(Theme.warning)
                }
            } else if beacon.oweTransition {
                row("Mode", "Ouvert, jumelé à un BSSID OWE")
            } else {
                Text("Aucun élément RSN ni WPA\u{00A0}: réseau ouvert ou WEP.")
                    .font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func apSection(_ network: WifiNetwork, _ beacon: WifiBeaconInfo) -> some View {
        section("Borne", symbol: "wifi.router") {
            row("Nom", beacon.apName ?? "non annoncé", color: beacon.apName == nil ? Theme.textTertiary : Theme.text)
            if let source = beacon.apNameSource { row("Source", source.label) }
            if let model = beacon.apModel { row("Modèle", model) }
            if let serial = beacon.apSerial { row("N° de série", serial, mono: true) }
            row("Fabricant", WifiText.vendor(network))
            if beacon.wpsDeviceName != nil || beacon.wpsModel != nil {
                row("WPS", [beacon.wpsManufacturer, beacon.wpsModel, beacon.wpsDeviceName].compactMap { $0 }.joined(separator: " · "))
            }
            if beacon.hotspot20 { row("Passpoint", "Hotspot 2.0 annoncé") }
        }
    }

    // MARK: Briques

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(Theme.captionSemibold)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.text, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            Text(value).font(mono ? Theme.mono(12) : .system(size: 12, weight: .semibold)).foregroundStyle(color)
                .lineLimit(2).multilineTextAlignment(.trailing)
        }
    }

    private func flag(_ label: String, _ on: Bool, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Theme.success : Theme.textTertiary)
                Text(label).font(Theme.small).foregroundStyle(on ? Theme.text : Theme.textSecondary).lineLimit(1)
            }
            if let detail {
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).padding(.leading, 18).lineLimit(1)
            }
        }
    }
}
