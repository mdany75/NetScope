import NetScopeCore
import SwiftUI

// Note 46 : ce qu'on sait d'un client Wi-Fi, mis en forme une fois pour la fiche du client
// (Wi-Fi › FortiAP) et pour la section Wi-Fi de la fiche Appareil. Un champ que la FortiGate ne
// donne pas s'affiche « — » (le diagnostic brut le note : FortiWifiClientFields).

/// Lignes de la fiche d'un client Wi-Fi, regroupées par thème.
struct WifiClientFacts {
    struct Row: Identifiable {
        var id: String { key }
        let key: String
        let value: String
        var mono = true
        var color: Color = Theme.text
        var detail: String?
        var help: String?
    }

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let rows: [Row]
    }

    let client: FortiWifiClient
    let ap: FortiManagedAP?
    let ssid: FortiSSID?
    let history: FortiWifiSignalHistory
    let device: Device?
    let thresholds: FortiWifiThresholds
    var now = Date()

    /// Radio de la borne qui sert le client (par numéro, sinon par bande).
    var radio: FortiAPRadio? {
        guard let ap else { return nil }
        if let id = client.radioID, let r = ap.radios.first(where: { $0.radioID == id }) { return r }
        return client.band.flatMap { ap.radio($0) }
    }

    var isWeak: Bool { FortiWifiAnalysis.isWeak(client, thresholds: thresholds) }
    var samples: [FortiWifiSignalSample] { history.samples(for: client.mac) }
    var roams: [FortiWifiRoam] { history.roams(for: client.mac) }
    var disconnections: [Date] { history.disconnections(for: client.mac).filter { $0 >= now.addingTimeInterval(-86_400) } }
    var trend: FortiWifiSignalTrend { history.trend(for: client.mac) }
    var issues: [FortiWifiClientIssue] {
        FortiWifiClientIssues.issues(client, ap: ap, history: history, thresholds: thresholds, now: now)
    }

    private static let dash = "—"

    private func text(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return Self.dash }
        return value
    }

    // MARK: Valeurs

    var rssiColor: Color {
        guard let rssi = client.rssi else { return Theme.text }
        return isWeak ? Theme.critical : WifiText.qualityColor(rssi).foreground
    }

    var snrColor: Color { (client.snr ?? 99) < thresholds.weakSNR ? Theme.critical : Theme.text }

    var vendor: String {
        if let given = client.manufacturer, !given.isEmpty { return given }
        let info = MACVendorLookup.info(for: client.mac)
        return info.vendor.map { "\($0) · \(info.oui)" } ?? info.vendorLabel
    }

    var radioLabel: String {
        guard let radio else { return client.radioID.map { "Radio \($0)" } ?? Self.dash }
        return "Radio \(radio.radioID)" + (radio.band.map { " · \($0.label)" } ?? "")
    }

    var channelLabel: String {
        let width = client.info.widthMHz ?? radio?.widthMHz
        var parts: [String] = []
        if let channel = client.channel ?? radio?.channel { parts.append("canal \(channel)") }
        if let width { parts.append("\(width)\u{00A0}MHz" + (client.info.widthMHz == nil ? " (radio)" : "")) }
        return parts.isEmpty ? Self.dash : parts.joined(separator: " · ")
    }

    var securityLabel: String {
        if let s = client.info.security, !s.isEmpty { return s }
        if let ssid, ssid.securityLabel != Self.dash { return ssid.securityLabel + " (SSID)" }
        return Self.dash
    }

    var authenticationLabel: String {
        if let a = client.info.authenticationLabel { return a }
        guard let raw = ssid?.security?.lowercased() else { return Self.dash }
        return FortiWifiClientDetails(security: raw).authenticationLabel.map { $0 + " (SSID)" } ?? Self.dash
    }

    var trendLabel: String { trend.label }

    /// « −77 / −65 / −55 dBm » (minimum, moyenne, maximum de l'historique).
    var rangeLabel: String {
        guard let r = history.range(for: client.mac) else { return Self.dash }
        return "\(r.min) / \(r.average) / \(r.max)\u{00A0}dBm"
    }

    var trendColor: Color {
        switch trend {
        case .falling: return Theme.warning
        case .rising: return Theme.success
        default: return Theme.text
        }
    }

    var roamLabel: String {
        guard let last = roams.last else { return samples.count > 1 ? "aucune vue" : Self.dash }
        return "\(roams.count) · dernière à \(WifiText.time(last.date))"
    }

    var disconnectLabel: String {
        samples.count > 1 ? (disconnections.isEmpty ? "aucune vue" : "\(disconnections.count) en 24\u{00A0}h") : Self.dash
    }

    var deviceLabel: String {
        guard let device else { return "pas dans le dernier scan" }
        return "\(device.displayName) · \(device.ip)"
    }

    static func bytes(_ value: Int64?) -> String { value.map { SNMPFormat.bytes(UInt64(max(0, $0))) } ?? dash }

    // MARK: Sections

    var identity: Section {
        Section(title: "Identité", rows: [
            Row(key: "Nom", value: text(client.hostname), mono: false),
            Row(key: "Fabricant (OUI)", value: vendor, mono: false),
            Row(key: "MAC", value: client.mac.formatted(.upperColon), detail: client.mac.isRandomized ? "privée" : nil),
            Row(key: "Adresse IP", value: client.ip?.description ?? Self.dash),
            Row(key: "VLAN", value: client.vlan.map(String.init) ?? ssid?.vlan.map { "\($0) (SSID)" } ?? Self.dash),
            Row(key: "Système", value: text(client.os), mono: false),
            Row(key: "Appareil du Scanner", value: deviceLabel, mono: false, color: device == nil ? Theme.textSecondary : Theme.text),
        ])
    }

    var connection: Section {
        Section(title: "Connexion", rows: [
            Row(key: "SSID", value: text(client.ssid), mono: false),
            Row(key: "Borne", value: (ap?.name ?? client.apName ?? Self.dash) + (ap.map { $0.model.isEmpty ? "" : " · \($0.model)" } ?? "")),
            Row(key: "Radio", value: radioLabel),
            Row(key: "Bande", value: client.band?.label ?? Self.dash),
            Row(key: "Canal et largeur", value: channelLabel),
            Row(key: "Standard", value: client.standard?.label ?? Self.dash, mono: false,
                help: client.info.standardText.map { "Donné par la FortiGate\u{00A0}: \($0)" }),
            Row(key: "Sécurité", value: securityLabel, mono: false),
            Row(key: "Authentification", value: authenticationLabel, mono: false),
            Row(key: "Utilisateur", value: text(client.info.user)),
            Row(key: "Itinérance assistée", value: client.info.roamingCapabilities ?? Self.dash, mono: false),
        ])
    }

    var signal: Section {
        Section(title: "Signal", rows: [
            Row(key: "RSSI", value: FortiAPText.dbm(client.rssi), color: rssiColor, detail: isWeak ? "signal faible" : nil),
            Row(key: "SNR", value: client.snr.map { "\($0)\u{00A0}dB" } ?? Self.dash, color: snrColor),
            Row(key: "Bruit", value: client.noise.map { "\($0)\u{00A0}dBm" } ?? radio?.noiseDBm.map { "\($0)\u{00A0}dBm (radio)" } ?? Self.dash),
            Row(key: "Tendance", value: trendLabel, mono: false, color: trendColor),
            Row(key: "Min / moy / max", value: rangeLabel, help: "RSSI le plus faible, moyen et le plus fort de l’historique"),
        ])
    }

    var traffic: Section {
        Section(title: "Débits et trafic", rows: [
            Row(key: "Débit négocié", value: FortiAPText.rate(client.rateMbps)),
            Row(key: "Descendant", value: FortiAPText.rate(client.info.txRateMbps), help: "De la borne vers le client"),
            Row(key: "Montant", value: FortiAPText.rate(client.info.rxRateMbps), help: "Du client vers la borne"),
            Row(key: "Débit maximal", value: FortiAPText.rate(client.info.maxRateMbps)),
            Row(key: "Octets reçus", value: Self.bytes(client.info.bytesToClient), help: "Envoyés par la borne au client"),
            Row(key: "Octets envoyés", value: Self.bytes(client.info.bytesFromClient), help: "Reçus du client par la borne"),
            Row(key: "Retransmissions", value: client.info.txRetryPercent.map { "\(Int($0.rounded()))\u{00A0}%" } ?? Self.dash),
            Row(key: "Associé depuis", value: FortiAPText.duration(client.associatedFor), mono: false),
            Row(key: "Itinérances", value: roamLabel, mono: false),
            Row(key: "Déconnexions", value: disconnectLabel, mono: false,
                color: disconnections.count >= 2 ? Theme.warning : Theme.text),
        ])
    }

    var accessPoint: Section {
        let radioClients = radio?.clientCount
        let busy = (radio?.channelUtilization ?? 0) > thresholds.maxChannelUtilization
        return Section(title: "Borne et canal", rows: [
            Row(key: "Clients de la radio", value: radioClients.map(String.init) ?? Self.dash,
                color: (radioClients ?? 0) > thresholds.maxClientsPerRadio ? Theme.warning : Theme.text),
            Row(key: "Clients de la borne", value: ap.map { String($0.totalClients) } ?? Self.dash),
            Row(key: "Utilisation du canal", value: FortiAPText.percent(radio?.channelUtilization), color: busy ? Theme.warning : Theme.text),
            Row(key: "Bruit de la radio", value: radio?.noiseDBm.map { "\($0)\u{00A0}dBm" } ?? Self.dash),
            Row(key: "Puissance d’émission", value: radio?.powerLabel ?? Self.dash),
            Row(key: "AP voisins gênants", value: radio?.interferingAPs.map(String.init) ?? Self.dash),
        ])
    }
}

// MARK: - Courbe du signal

/// Historique du RSSI d'un client : une courbe, le seuil du signal faible en pointillé, les
/// itinérances en traits verticaux, une coupure là où le client a manqué une lecture.
struct WifiSignalHistoryChart: View {
    let samples: [FortiWifiSignalSample]
    let roams: [FortiWifiRoam]
    let readings: [Date]
    let threshold: Int
    var height: CGFloat = 150

    var body: some View {
        if samples.compactMap(\.rssi).count < 2 {
            Text(samples.isEmpty ? "Aucun relevé encore\u{00A0}: l’historique se remplit à chaque lecture des bornes."
                 : "Un seul relevé pour l’instant\u{00A0}: la courbe apparaît dès la prochaine lecture des bornes.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            chart
        }
    }

    private var chart: some View {
        Canvas { context, size in
            let left: CGFloat = 34, right = size.width - 6, top: CGFloat = 8, bottom = size.height - 20
            let start = samples.first?.date ?? Date(), end = samples.last?.date ?? Date()
            let span = max(60, end.timeIntervalSince(start))
            func x(_ date: Date) -> CGFloat { left + CGFloat(date.timeIntervalSince(start) / span) * (right - left) }
            func y(_ rssi: Int) -> CGFloat { top + CGFloat(Double(-35 - max(-95, min(-35, rssi))) / 60) * (bottom - top) }
            let labelColor = Theme.textSecondary

            for level in [-40, -50, -60, -70, -80, -90] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y(level)))
                line.addLine(to: CGPoint(x: right, y: y(level)))
                context.stroke(line, with: .color(Theme.border), lineWidth: 1)
                context.draw(Text("\u{2212}\(abs(level))").font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                             at: CGPoint(x: left - 4, y: y(level)), anchor: .trailing)
            }
            // Seuil du signal faible.
            var limit = Path()
            limit.move(to: CGPoint(x: left, y: y(threshold)))
            limit.addLine(to: CGPoint(x: right, y: y(threshold)))
            context.stroke(limit, with: .color(Theme.critical.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.draw(Text("seuil \u{2212}\(abs(threshold))").font(.system(size: 9)).foregroundStyle(Theme.critical),
                         at: CGPoint(x: right - 2, y: y(threshold) - 2), anchor: .bottomTrailing)

            // Itinérances.
            for roam in roams {
                var mark = Path()
                mark.move(to: CGPoint(x: x(roam.date), y: top))
                mark.addLine(to: CGPoint(x: x(roam.date), y: bottom))
                context.stroke(mark, with: .color(Theme.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Courbe, coupée là où le client a manqué une lecture (déconnexion).
            let present = Set(samples.map(\.date))
            let missed = readings.filter { $0 > start && $0 < end && !present.contains($0) }
            var path = Path()
            var drawing = false
            var previous: Date?
            for sample in samples {
                guard let rssi = sample.rssi else { drawing = false; continue }
                if let previous, missed.contains(where: { $0 > previous && $0 < sample.date }) { drawing = false }
                let point = CGPoint(x: x(sample.date), y: y(rssi))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
                previous = sample.date
            }
            context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let lastSample = samples.last(where: { $0.rssi != nil }), let rssi = lastSample.rssi {
                let p = CGPoint(x: x(lastSample.date), y: y(rssi))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                             with: .color(WifiText.qualityColor(rssi).foreground))
            }

            var axis = Path()
            axis.move(to: CGPoint(x: left, y: bottom))
            axis.addLine(to: CGPoint(x: right, y: bottom))
            context.stroke(axis, with: .color(Theme.borderStrong), lineWidth: 1)
            context.draw(Text(WifiText.time(start)).font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                         at: CGPoint(x: left, y: bottom + 10), anchor: .leading)
            context.draw(Text(WifiText.time(start.addingTimeInterval(span / 2))).font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                         at: CGPoint(x: (left + right) / 2, y: bottom + 10))
            context.draw(Text(WifiText.time(end)).font(.system(size: 9, design: .monospaced)).foregroundStyle(labelColor),
                         at: CGPoint(x: right, y: bottom + 10), anchor: .trailing)
            context.draw(Text("dBm").font(.system(size: 9)).foregroundStyle(labelColor), at: CGPoint(x: 2, y: 0), anchor: .topLeading)
        }
        .frame(height: height)
        .accessibilityLabel("Historique du signal\u{00A0}: \(samples.count) relevés")
    }
}

// MARK: - Problèmes repérés

/// Liste compacte des problèmes repérés (même habillage que les conseils de l'écran Wi-Fi).
struct WifiClientIssuesList: View {
    let issues: [FortiWifiClientIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { issue in
                let (foreground, background, symbol) = FortiAPText.severityColors(issue.severity)
                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(background)
                        Image(systemName: issue.kind == .healthy ? "checkmark" : symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(issue.kind == .healthy ? Theme.success : foreground)
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(issue.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Itinérances

struct WifiRoamList: View {
    let roams: [FortiWifiRoam]
    var limit = 5

    var body: some View {
        if roams.isEmpty {
            Text("Aucune itinérance vue dans l’historique.").font(Theme.small).foregroundStyle(Theme.textSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(roams.suffix(limit).reversed()) { roam in
                    HStack(spacing: 8) {
                        Text(WifiText.time(roam.date)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).fixedSize()
                        Text(roam.label).font(Theme.small).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if let before = roam.rssiBefore, let after = roam.rssiAfter {
                            Text("\(before) → \(after)\u{00A0}dBm").font(Theme.mono(11))
                                .foregroundStyle(after < before ? Theme.warning : Theme.success).fixedSize()
                        }
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: - Diagnostiquer (note 47)

/// Emplacement du bouton « Diagnostiquer » (note 47) dans la fiche du client et dans la section
/// Wi-Fi de la fiche Appareil. À LA FUSION avec la note 47 : remplacer le corps par
/// `WifiDiagnoseButton(client: client, site: site)`.
struct WifiDiagnoseSlot: View {
    let client: FortiWifiClient
    /// Site du client (clé `SiteFiles.key`).
    let site: String

    var body: some View {
        Button {} label: { Label("Diagnostiquer — bientôt", systemImage: "stethoscope") }
            .buttonStyle(.secondary)
            .disabled(true)
            .help("Diagnostic complet du Wi-Fi de ce client, avec les solutions (note 47)")
    }
}
