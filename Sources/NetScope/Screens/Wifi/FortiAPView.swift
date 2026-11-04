import NetScopeCore
import SwiftUI

// Note 27 : partie « FortiAP » de l'écran Wi-Fi. Bornes, clients, SSID et AP voisins lus par les
// FortiGate choisies pour les switchs, carte des canaux et conseils. Même habillage que l'analyse
// locale (croquis Wifi.dc.html) : intertitres en petites majuscules, tuiles, tableaux standard.

/// Mise en forme commune de la partie FortiAP.
enum FortiAPText {
    /// « 18 j 4 h », « 3 h 12 min », « 14 min ».
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)\u{00A0}j \(h)\u{00A0}h" }
        if h > 0 { return "\(h)\u{00A0}h \(m)\u{00A0}min" }
        return "\(max(m, 0))\u{00A0}min"
    }

    /// « 866,7 Mb/s », « 72 Mb/s ».
    static func rate(_ mbps: Double?) -> String {
        guard let mbps else { return "—" }
        return (mbps >= 100 || mbps == mbps.rounded() ? "\(Int(mbps.rounded()))" : ToolFormat.decimal(mbps)) + "\u{00A0}Mb/s"
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))\u{00A0}%" } ?? "—"
    }

    static func dbm(_ value: Int?) -> String { value.map(WifiQuality.dbm) ?? "—" }

    /// Résumé des radios : « 2,4 : 6 · 5 : 44 (80) ».
    static func radios(_ ap: FortiManagedAP) -> String {
        let parts = ap.radios.compactMap { r -> String? in
            guard let band = r.band else { return nil }
            let name = band.label.replacingOccurrences(of: "\u{00A0}GHz", with: "").replacingOccurrences(of: " GHz", with: "")
            // Radio éteinte ou en mode moniteur (analyse) : absente du résumé, détaillée dans la fiche.
            guard r.isServing, let ch = r.channel else { return nil }
            return "\(name)\u{00A0}: \(ch)" + (band == .ghz24 && r.effectiveWidth == 20 ? "" : " (\(r.effectiveWidth))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func severityColors(_ severity: WifiRecommendation.Severity) -> (Color, Color, String) {
        switch severity {
        case .critique: return (Theme.critical, Theme.criticalSoft, "exclamationmark.octagon")
        case .alerte: return (Theme.warning, Theme.warningSoft, "exclamationmark.triangle")
        case .conseil: return (Theme.accentStrong, Theme.accentSoft, "lightbulb")
        case .info: return (Theme.neutralText, Theme.neutralSoft, "info.circle")
        }
    }

    /// Pastille d'état d'une borne.
    static func statePill(_ ap: FortiManagedAP) -> WifiPill {
        switch ap.connected {
        case true?: return WifiPill(text: "En ligne", foreground: Theme.success, background: Theme.successSoft)
        case false?: return WifiPill(text: "Hors ligne", foreground: Theme.critical, background: Theme.criticalSoft)
        case nil: return WifiPill(text: ap.state ?? "Inconnu")
        }
    }
}

/// Choix de la partie de l'écran Wi-Fi.
enum WifiScreenPart: String, CaseIterable, Identifiable {
    case local, fortiap
    var id: String { rawValue }
    var label: String { self == .local ? "Ce Mac" : "FortiAP" }
}

/// Partie FortiAP : bandeau de la FortiGate, tuiles, tableaux, carte des canaux, conseils.
struct FortiAPView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @State private var selectedAP: FortiManagedAP.ID?
    @State private var band: WifiBand = .ghz5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !fortigate.isConfigured {
                notConfigured
            } else {
                FortiAPBanner()
                if store.hasData {
                    tiles
                    SidePanelSplit(sideWidth: 320, collapse: .below) {
                        VStack(spacing: 14) {
                            FortiAPTable(selection: $selectedAP)
                            FortiAPChannelMap(band: $band, selectedAP: $selectedAP)
                            FortiAPClientTable()
                            FortiAPSSIDTable()
                            FortiAPRogueTable()
                        }
                    } side: {
                        VStack(spacing: 14) {
                            FortiAPAdvicePanel(selectedAP: $selectedAP, band: $band)
                            FortiAPDetailPanel(apID: selectedAP)
                        }
                    }
                } else {
                    noData
                }
            }
        }
        .onAppear {
            applyFocus()
            if selectedAP == nil { selectedAP = store.overview.aps.first?.id }
        }
        .onChange(of: store.focusAP) { _, _ in applyFocus() }
        .onChange(of: store.overview.aps.map(\.id)) { _, ids in
            if let id = selectedAP, ids.contains(id) { return }
            selectedAP = ids.first
        }
    }

    /// Borne demandée par la fiche d'un appareil : sélectionnée, et sa bande montrée sur la carte.
    private func applyFocus() {
        guard let id = store.focusAP else { return }
        if store.overview.aps.contains(where: { $0.id == id }) {
            selectedAP = id
            if let b = store.focusBand { band = b }
        }
        store.focusAP = nil
        store.focusBand = nil
    }

    private var notConfigured: some View {
        Panel(padding: 0) {
            EmptyState(systemImage: "wifi.router",
                       title: "Aucune FortiGate configurée",
                       message: "Les bornes FortiAP sont lues par la FortiGate de chaque site (API REST, lecture seule), la même que pour les FortiSwitch. Ajoutez la FortiGate et son jeton dans Réglages › Switchs › Contrôleurs FortiGate.") {
                Button("Ouvrir Réglages › Switchs") {
                    RegNavigation.shared.section = .switchs
                    state.open(.reglages)
                }
                .buttonStyle(.primary)
            }
            .frame(height: 240)
        }
    }

    private var noData: some View {
        Panel(padding: 0) {
            EmptyState(systemImage: store.busy ? "hourglass" : "wifi.exclamationmark",
                       title: store.busy ? "Lecture des bornes FortiAP…" : "Aucune borne FortiAP lue",
                       message: store.lastRefresh == nil
                        ? "Les bornes sont lues avec les FortiSwitch à la fin de chaque scan, ou par «\u{00A0}Relire les bornes\u{00A0}»."
                        : "La FortiGate n’a renvoyé aucune borne FortiAP. Si elle en gère, vérifiez le droit «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture du profil de l’administrateur API.")
                .frame(height: 220)
        }
    }

    // MARK: Tuiles

    private var tiles: some View {
        let o = store.overview
        let d = store.diagnosis
        let critical = d.advice.filter { $0.severity == .critique }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
            tile("Bornes en ligne", "\(o.onlineAPs.count) / \(o.aps.count)",
                 sub: o.isMultiSite ? "\(o.sites.count) sites" : (o.sites.first ?? ""), color: Theme.success)
            tile("Hors ligne", "\(o.offlineAPs.count)", sub: o.offlineAPs.first.map { $0.name + (o.offlineAPs.count > 1 ? "…" : "") } ?? "aucune",
                 color: o.offlineAPs.isEmpty ? Theme.text : Theme.critical)
            tile("Clients Wi-Fi", "\(o.clients.count)",
                 sub: "\(d.weakClients.count) à signal faible", color: Theme.text)
            tile("SSID", "\(o.distinctSSIDs.count)", sub: o.distinctSSIDs.prefix(2).joined(separator: ", "), color: Theme.text)
            tile("Alertes", "\(d.alertCount)", sub: critical > 0 ? "dont \(critical) critique\(critical > 1 ? "s" : "")" : "aucune critique",
                 color: critical > 0 ? Theme.critical : (d.alertCount > 0 ? Theme.warning : Theme.success))
        }
    }

    private func tile(_ title: String, _ value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(Theme.mono(18, weight: .bold)).foregroundStyle(color).lineLimit(1)
            Text(sub).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .modifier(WifiTileStyle())
    }
}

// MARK: - Bandeau « FortiGate utilisée »

struct FortiAPBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        let selection = store.lastRefresh == nil || store.selection.isEmpty ? fortigate.previewSelection(state: state) : store.selection
        Panel(padding: 14) {
            AdaptiveStack(breakpoint: 860, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                        Image(systemName: "wifi.router").font(.system(size: 15)).foregroundStyle(Theme.accentStrong)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        headline(selection).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail(selection)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Adresses lues en GET\u{00A0}: " + FortiWifiPaths.all.joined(separator: ", "))
                        ForEach(selection.picks.filter { store.errors[$0.controllerID] != nil }) { pick in
                            Label("\(pick.site)\u{00A0}: \(store.errors[pick.controllerID] ?? "")", systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.small).foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Réglages…") {
                        RegNavigation.shared.section = .switchs
                        state.open(.reglages)
                    }
                    .buttonStyle(.secondary)
                    Button { store.refreshNow(state: state) } label: {
                        HStack(spacing: 6) {
                            if store.busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            }
                            Text(store.busy ? "Lecture…" : "Relire les bornes")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(store.busy || !store.canRefresh(state: state))
                    .help("Relit, par l’API REST (HTTPS, lecture seule), les bornes FortiAP, les clients Wi-Fi, les SSID et les AP voisins des FortiGate qui couvrent les plages cochées du Scanner (sinon l’adresse de ce Mac).")
                }
                .fixedSize()
            }
        }
    }

    private func headline(_ selection: FortiControllerSelection) -> Text {
        guard fortigate.isEnabled else { return Text("FortiGate\u{00A0}: lecture désactivée") }
        switch selection.picks.count {
        case 0: return Text("Aucune FortiGate pour cette plage")
        case 1:
            let pick = selection.picks[0]
            return Text("FortiGate utilisée\u{00A0}: ") + Text(pick.site)
                + (pick.coveredRanges.isEmpty ? Text("") : Text(" (") + Text(pick.rangeLabel).font(Theme.mono(12.5, weight: .semibold)) + Text(")"))
        default:
            return Text("FortiGate utilisées\u{00A0}: ") + Text(selection.picks.map(\.site).joined(separator: ", "))
        }
    }

    private func detail(_ selection: FortiControllerSelection) -> String {
        guard fortigate.isEnabled else { return "Lecture des FortiGate désactivée dans Réglages › Switchs." }
        if selection.isEmpty {
            return "Ni les plages cochées ni l’adresse de ce Mac ne sont couvertes par une FortiGate de la liste. Ajoutez la plage au site concerné dans Réglages › Switchs."
        }
        let o = store.overview
        guard let last = store.lastRefresh else {
            return "Les bornes FortiAP sont lues avec les FortiSwitch à la fin du scan, par les mêmes FortiGate."
        }
        let read = "\(o.aps.count) borne\(o.aps.count > 1 ? "s" : ""), \(o.clients.count) client\(o.clients.count > 1 ? "s" : "") Wi-Fi"
        return "\(read) · lu à \(WifiText.timeSeconds(last)) (bornes, clients, SSID et AP voisins)."
    }
}

// MARK: - Conseils

struct FortiAPAdvicePanel: View {
    @ObservedObject private var store = FortiAPStore.shared
    @Binding var selectedAP: FortiManagedAP.ID?
    @Binding var band: WifiBand
    @State private var showThresholds = false

    var body: some View {
        let advice = store.diagnosis.advice
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading("Conseils")
                    Text("\(advice.count)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.neutralText)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.neutralSoft))
                    Spacer()
                    Button { showThresholds = true } label: { Label("Seuils", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .popover(isPresented: $showThresholds, arrowEdge: .bottom) { FortiAPThresholdsForm() }
                        .help("Seuils du signal faible et de la surcharge")
                }
                ForEach(advice) { item in card(item) }
            }
        }
    }

    private func card(_ item: FortiWifiAdvice) -> some View {
        let (foreground, background, symbol) = FortiAPText.severityColors(item.severity)
        return HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(background)
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(foreground)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.severity.label.uppercased())
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(foreground)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(background))
                Text(item.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(item.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let name = item.apName, let ap = store.overview.aps.first(where: { $0.name == name && (item.site == nil || $0.site == item.site) }) {
                    Button("Voir la borne") {
                        selectedAP = ap.id
                        if let b = item.band { band = b }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 3)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Seuils réglables du diagnostic.
struct FortiAPThresholdsForm: View {
    @ObservedObject private var store = FortiAPStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seuils du diagnostic Wi-Fi").font(Theme.bodySemibold)
            Stepper(value: Binding(get: { store.thresholds.weakRSSI }, set: { store.thresholds.weakRSSI = $0 }), in: -90 ... -50) {
                Text("Signal faible sous \(store.thresholds.weakRSSI)\u{00A0}dBm").font(Theme.small)
            }
            Stepper(value: Binding(get: { store.thresholds.weakSNR }, set: { store.thresholds.weakSNR = $0 }), in: 5...40) {
                Text("ou SNR sous \(store.thresholds.weakSNR)\u{00A0}dB").font(Theme.small)
            }
            Stepper(value: Binding(get: { store.thresholds.maxClientsPerRadio }, set: { store.thresholds.maxClientsPerRadio = $0 }), in: 5...200, step: 5) {
                Text("Surcharge au-delà de \(store.thresholds.maxClientsPerRadio) clients par radio").font(Theme.small)
            }
            Stepper(value: Binding(get: { store.thresholds.maxChannelUtilization }, set: { store.thresholds.maxChannelUtilization = $0 }),
                    in: 30...95, step: 5) {
                Text("ou canal occupé à plus de \(Int(store.thresholds.maxChannelUtilization))\u{00A0}%").font(Theme.small)
            }
            HStack {
                Spacer()
                Button("Valeurs par défaut") { store.thresholds = .standard }
                    .disabled(store.thresholds == .standard)
            }
        }
        .padding(14)
        .frame(width: 330)
    }
}

// MARK: - Détail d'une borne

struct FortiAPDetailPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let apID: FortiManagedAP.ID?

    var body: some View {
        Panel(padding: 14) {
            if let ap = store.overview.aps.first(where: { $0.id == apID }) {
                content(ap)
            } else {
                Text("Choisissez une borne dans le tableau.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func content(_ ap: FortiManagedAP) -> some View {
        let clients = store.overview.clients(of: ap)
        let device = ap.ip.flatMap { state.device(withID: $0.description) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WifiHeading("Borne")
                Spacer()
                FortiAPText.statePill(ap)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ap.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text([ap.model, ap.firmwareShort, store.overview.isMultiSite ? ap.site : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            VStack(spacing: 0) {
                KeyValueRow(key: "Adresse IP", value: ap.ip?.description ?? "—", mono: true, keyWidth: 96)
                KeyValueRow(key: "Série", value: ap.serial.isEmpty ? "—" : ap.serial, mono: true, keyWidth: 96)
                KeyValueRow(key: ap.isOffline ? "Vue il y a" : "En service", value: ap.isOffline
                            ? FortiAPText.duration(ap.lastSeen.map { Date().timeIntervalSince($0) }) : FortiAPText.duration(ap.uptime), keyWidth: 96)
                KeyValueRow(key: "Profil", value: ap.profile ?? "—", mono: true, keyWidth: 96)
                if let location = ap.location { KeyValueRow(key: "Emplacement", value: location, keyWidth: 96) }
                if let device, let place = device.switchLocation {
                    KeyValueRow(key: "Branchée sur", value: place, mono: true, keyWidth: 96)
                }
            }
            WifiHeading("Radios")
            VStack(spacing: 6) {
                ForEach(ap.radios) { radio in radioRow(radio, ap: ap) }
            }
            if !clients.isEmpty {
                WifiHeading("Clients les plus faibles")
                VStack(spacing: 0) {
                    ForEach(clients.sorted { ($0.rssi ?? 0) < ($1.rssi ?? 0) }.prefix(5)) { client in
                        HStack(spacing: 8) {
                            Text(client.displayName).font(Theme.small).lineLimit(1)
                            Spacer(minLength: 4)
                            if let rssi = client.rssi {
                                WifiSignalBar(rssi: rssi, width: 34)
                                Text(WifiQuality.dbm(rssi)).font(Theme.mono(11, weight: .semibold))
                                    .foregroundStyle(WifiText.qualityColor(rssi).foreground).frame(width: 62, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 4)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
            }
            if let device {
                Button("Ouvrir la fiche de la borne →") { state.showDevice(device.id) }
                    .buttonStyle(.ghost)
                    .padding(.leading, -8)
            }
        }
    }

    private func radioRow(_ radio: FortiAPRadio, ap: FortiManagedAP) -> some View {
        let util = radio.channelUtilization
        let busy = (util ?? 0) > store.thresholds.maxChannelUtilization
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Radio \(radio.radioID)").font(.system(size: 12, weight: .semibold))
                Text(radio.isServing ? radio.label : (radio.mode?.lowercased().contains("monitor") == true ? "\(radio.band?.label ?? "") · moniteur (analyse)" : "Éteinte"))
                    .font(Theme.mono(11)).foregroundStyle(radio.isServing ? Theme.neutralText : Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            if radio.isServing {
                // Deux lignes : clients, puissance et bruit ; puis l'occupation du canal (le tout tenait
                // mal sur une ligne dans le panneau de 300 points : « 14 dBm » passait à la ligne).
                HStack(spacing: 8) {
                    Text("\(radio.clientCount ?? 0) client\((radio.clientCount ?? 0) > 1 ? "s" : "")").font(Theme.caption)
                        .lineLimit(1).fixedSize()
                    if let p = radio.powerLabel {
                        Text("émission\u{00A0}\(p)").font(Theme.mono(11)).lineLimit(1).fixedSize()
                            .help("Puissance d'émission de la radio")
                    }
                    if let n = radio.noiseDBm { Text("bruit\u{00A0}\(n)\u{00A0}dBm").font(Theme.mono(11)).lineLimit(1).fixedSize() }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                if let util {
                    HStack(spacing: 8) {
                        Text("Canal occupé").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.border)
                                Capsule().fill(busy ? Theme.warning : Theme.accent).frame(width: geo.size.width * CGFloat(min(util, 100)) / 100)
                            }
                        }
                        .frame(height: 5)
                        Text(FortiAPText.percent(util)).font(Theme.mono(11, weight: .semibold))
                            .foregroundStyle(busy ? Theme.warning : Theme.neutralText).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(busy ? Theme.warning.opacity(0.6) : Theme.border))
    }
}
