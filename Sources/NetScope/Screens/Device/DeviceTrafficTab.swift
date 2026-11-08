import NetScopeCore
import SwiftUI

// Note 105 : ce que l'écran Trafic sait d'une adresse, dans sa fiche. Onglet « Trafic » (mêmes
// tuiles et mêmes tableaux que l'écran Trafic) et carte de résumé dans l'Aperçu.

/// Partie de l'onglet Trafic.
private enum DeviceTrafficPart: String, CaseIterable, Identifiable {
    case destinations, applications, sessions, threats

    var id: String { rawValue }

    var label: String {
        switch self {
        case .destinations: return "Destinations"
        case .applications: return "Applications"
        case .sessions: return "Sessions"
        case .threats: return "Menaces"
        }
    }

    /// Captures : NETSCOPE_DEVICE_TAB=trafic NETSCOPE_DEVICE_TRAFIC=applications (ou sessions, threats).
    static var initial: DeviceTrafficPart {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_DEVICE_TRAFIC"],
              let part = DeviceTrafficPart(rawValue: raw) else { return .destinations }
        return part
    }
}

/// Onglet Trafic de la fiche.
struct DeviceTrafficTab: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = DeviceTrafficStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @ObservedObject private var sites = SiteModel.shared
    let device: Device
    @State private var part = DeviceTrafficPart.initial

    private var blocker: String? { store.blocker(manual: state.manualEntry(forID: device.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let blocker {
                ToolNotice(tone: .accent, title: "Trafic non disponible", message: blocker)
            } else {
                status
                if let error = store.errorWithAge {
                    ToolNotice(tone: .critical, title: "Lecture du trafic impossible", message: error)
                }
                if let overview = store.overview {
                    if overview.isIdle {
                        ToolNotice(tone: .accent, title: "Aucun trafic vu par la FortiGate",
                                   message: "Cet appareil est inactif, ou il ne communique que dans son VLAN\u{00A0}: ce trafic local ne passe pas par la FortiGate.")
                    }
                    tiles(overview)
                    picker(overview)
                    table(overview)
                    notes(overview)
                } else if store.isReading {
                    ToolNotice(tone: .accent, title: "Lecture de FortiView…", message: "Sessions, débit et menaces de cette adresse.")
                }
            }
        }
        .onAppear { store.loadDemoNow(device) }
        .task { await fortigate.loadTokens() }
        .task(id: blocker == nil ? DeviceTrafficStore.key(device) : "") {
            if blocker == nil { await store.runLive(device, every: DeviceTrafficStore.tabSeconds) }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Text("FortiView · \(sites.activeName) · en direct, relu toutes les \(DeviceTrafficStore.tabSeconds)\u{00A0}s")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            if store.isReading && store.overview == nil { ProgressView().controlSize(.small) }
        }
        .help("Seul le trafic qui traverse la FortiGate est visible\u{00A0}: une copie vers un serveur du même VLAN ne l’est pas.")
    }

    private func tiles(_ overview: DeviceTrafficOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            InvTile(title: "Débit", value: overview.bandwidth.map(TrafficFormat.rate) ?? "—", subtitle: rateDetail(overview))
            InvTile(title: "Envoyé", value: TrafficFormat.bytes(overview.sentBytes), subtitle: "Sessions en cours")
            InvTile(title: "Reçu", value: TrafficFormat.bytes(overview.receivedBytes), subtitle: "Sessions en cours")
            InvTile(title: "Sessions en cours", value: ToolFormat.integer(overview.sessionCount),
                    subtitle: "\(overview.destinations.count) destination\(overview.destinations.count > 1 ? "s" : "")",
                    action: { part = .sessions })
            InvTile(title: "Applications", value: "\(overview.applications.count)",
                    subtitle: overview.topApplication?.name ?? "Aucune en cours", action: { part = .applications })
            let passed = overview.threats.filter { !$0.isBlocked }.count
            InvTile(title: "Menaces", value: "\(overview.threats.count)",
                    subtitle: overview.threats.isEmpty ? "Aucune en temps réel" : (passed == 0 ? "Toutes bloquées" : "\(passed) non bloquée\(passed > 1 ? "s" : "")"),
                    valueColor: passed > 0 ? Theme.critical : (overview.threats.isEmpty ? Theme.text : Theme.warning),
                    tint: passed > 0 ? .critical : nil, action: { part = .threats })
        }
    }

    private func rateDetail(_ overview: DeviceTrafficOverview) -> String {
        guard let down = overview.receiveBps, let up = overview.sendBps else { return "Temps réel" }
        return "↓\u{00A0}" + TrafficFormat.rate(down) + " · ↑\u{00A0}" + TrafficFormat.rate(up)
    }

    private func label(_ part: DeviceTrafficPart, _ overview: DeviceTrafficOverview) -> String {
        let count: Int
        switch part {
        case .destinations: count = overview.destinations.count
        case .applications: count = overview.applications.count
        case .sessions: count = overview.sessions.count
        case .threats: count = overview.threats.count
        }
        return count > 0 ? "\(part.label) (\(count))" : part.label
    }

    private func picker(_ overview: DeviceTrafficOverview) -> some View {
        Picker("Vue", selection: $part) {
            ForEach(DeviceTrafficPart.allCases) { Text(label($0, overview)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    @ViewBuilder private func table(_ overview: DeviceTrafficOverview) -> some View {
        switch part {
        case .destinations:
            TrafficEntryTable(view: .destinations, rows: destinationRows(overview), multiSite: false,
                              emptyOverride: "Aucune destination en cours.") { EmptyView() }
                .id(part)
        case .applications:
            TrafficEntryTable(view: .applications, rows: plainRows(overview.applications), multiSite: false,
                              emptyOverride: "Aucune application en cours.") { EmptyView() }
                .id(part)
        case .sessions:
            TrafficSessionTable(rows: sessionRows(overview), multiSite: false, emptyOverride: "Aucune session en cours.") { EmptyView() }
        case .threats:
            TrafficEntryTable(view: .threats, rows: threatRows(overview), multiSite: false,
                              emptyOverride: "Aucune menace en temps réel pour cet appareil.") { EmptyView() }
                .id(part)
        }
    }

    private func plainRows(_ entries: [TrafficEntry]) -> [TrafficRow] {
        entries.map { TrafficRow(entry: $0, name: $0.name, ref: nil, location: nil, accessPoint: nil, link: nil) }
    }

    /// Une destination connue de NetScope (autre appareil du site de la fiche) porte son nom et s'ouvre.
    private func destinationRows(_ overview: DeviceTrafficOverview) -> [TrafficRow] {
        let traffic = TrafficStore.shared
        return overview.destinations.map { entry in
            let known = traffic.knownDeviceRef(ip: entry.ip, siteKey: sites.activeKey, state: state)
            let name = known.flatMap { $0.name != $0.ip ? $0.name : nil } ?? entry.name
            return TrafficRow(entry: entry, name: name, ref: known, location: nil, accessPoint: nil, link: nil)
        }
    }

    /// Menaces : la colonne Appareil montre cet appareil (comme l'écran Trafic).
    private func threatRows(_ overview: DeviceTrafficOverview) -> [TrafficRow] {
        overview.threats.map {
            TrafficRow(entry: $0, name: device.displayName, ref: nil, location: nil, accessPoint: nil, link: nil)
        }
    }

    private func sessionRows(_ overview: DeviceTrafficOverview) -> [TrafficSessionRow] {
        let traffic = TrafficStore.shared
        return overview.sessions.map { session in
            let name = session.source == device.ip ? device.displayName : nil
            let ref = name == nil ? traffic.knownDeviceRef(ip: session.source, siteKey: sites.activeKey, state: state) : nil
            return TrafficSessionRow(session: session, sourceName: name ?? ref?.name ?? session.source?.description ?? "—", ref: ref,
                                     rowID: DeviceTrafficAnalysis.sessionKey(session))
        }
    }

    @ViewBuilder private func notes(_ overview: DeviceTrafficOverview) -> some View {
        if !overview.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(overview.notes, id: \.self) { note in
                    Text("• " + note).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Résumé du trafic dans l'Aperçu ; absent si le site n'a pas de FortiGate prête.
struct DeviceTrafficCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = DeviceTrafficStore.shared
    @ObservedObject private var session = DeviceSession.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    let device: Device

    private var blocker: String? { store.blocker(manual: state.manualEntry(forID: device.id)) }

    var body: some View {
        if blocker == nil {
            DeviceCard(title: "Trafic en direct") {
                VStack(spacing: 0) {
                    if let overview = store.overview {
                        rows(overview)
                    } else if store.error == nil {
                        DeviceKVRow(key: "Débit", value: "Lecture…", mono: false, valueColor: Theme.textSecondary)
                    }
                    // Aussi sous d'anciens chiffres : ils ne doivent pas passer pour du direct.
                    if let error = store.errorWithAge {
                        Text(error).font(Theme.small).foregroundStyle(Theme.critical)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button("Voir le trafic") { session.tab = .trafic }
                            .buttonStyle(.secondary)
                            .controlSize(.small)
                            .help("Destinations, applications, sessions et menaces de cet appareil")
                    }
                    .padding(.top, 8)
                }
            }
            .onAppear { store.loadDemoNow(device) }
            .task(id: DeviceTrafficStore.key(device)) {
                await store.runLive(device, every: DeviceTrafficStore.overviewSeconds)
            }
        }
    }

    @ViewBuilder private func rows(_ overview: DeviceTrafficOverview) -> some View {
        if overview.isIdle {
            DeviceKVRow(key: "Débit", value: "Aucun trafic vu par la FortiGate", mono: false, valueColor: Theme.textSecondary)
        } else {
            DeviceKVRow(key: "Débit", value: overview.bandwidth.map(TrafficFormat.rate) ?? "—")
            DeviceKVRow(key: "Envoyé / reçu", value: TrafficFormat.bytes(overview.sentBytes) + " / " + TrafficFormat.bytes(overview.receivedBytes))
            DeviceKVRow(key: "Sessions en cours", value: ToolFormat.integer(overview.sessionCount))
            DeviceKVRow(key: "Application principale", value: overview.topApplication?.name ?? "—", mono: false)
            DeviceKVRow(key: "Destination principale", value: overview.topDestination?.name ?? "—")
            DeviceKVRow(key: "Menaces", value: "\(overview.threats.count)",
                        valueColor: overview.threats.isEmpty ? Theme.text : Theme.warning)
        }
    }
}
