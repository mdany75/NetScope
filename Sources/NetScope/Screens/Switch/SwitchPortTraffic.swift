import NetScopeCore
import SwiftUI

// Trafic des ports d'un switch (note 21) : panneau du port choisi (débit en direct, charge du lien,
// erreurs et rejets, courbe des 5 dernières minutes) et « ports les plus chargés » du switch.
// Relevés SNMP v2c en lecture (IF-MIB), partagés avec la fiche Appareil du switch.

/// Panneau « Trafic du port » sous le détail du port sélectionné.
struct SwitchPortTraffic: View {
    @ObservedObject var monitor: SNMPResourceMonitor
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let load = monitor.load(of: iface.index)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SwitchFieldLabel("Trafic du port · \(iface.name)")
                Spacer(minLength: 4)
                if monitor.isPolling { ProgressView().controlSize(.small) }
                Menu {
                    Picker("Intervalle", selection: $monitor.interval) {
                        ForEach(ResourceInterval.snmp, id: \.self) { Text(ResourceInterval.everyLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(monitor.isPaused ? "Reprendre les relevés" : "Suspendre les relevés") { monitor.togglePause() }
                    Button("Exporter l’historique du port (CSV)") {
                        monitor.exportCSV(port: iface.index, name: "trafic-\(snapshot.displayName)-\(iface.name.replacingOccurrences(of: "/", with: "-"))")
                    }
                    .disabled(monitor.timeline.samples.isEmpty)
                } label: {
                    Label(ResourceInterval.label(monitor.interval), systemImage: monitor.isPaused ? "pause.circle" : "clock")
                        .font(Theme.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Intervalle des relevés, pause et export CSV")
            }
            if let toast = monitor.toast {
                ResourceToastText(toast: toast)
            }
            if let error = monitor.error {
                Text(error).font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            }
            if !iface.isUp {
                Text("Port inactif\u{00A0}: aucun trafic à mesurer.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else if let load {
                rates(load)
                ResourceChart(series: [ResourceChartSeries(label: "Entrée", color: ResourceColors.primary, values: monitor.timeline.series("if\(iface.index).in")),
                                       ResourceChartSeries(label: "Sortie", color: ResourceColors.secondary, values: monitor.timeline.series("if\(iface.index).out"))],
                              axisLabel: { ResourceFormat.bitsPerSecond($0) }, span: monitor.timeline.window, height: 90, filled: false)
                HStack {
                    ResourceLegend(items: [("Entrée", ResourceColors.primary), ("Sortie", ResourceColors.secondary)])
                    Spacer(minLength: 4)
                    Text(counterNote(load)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                errors(load)
            } else {
                Text(monitor.lastPoll == nil ? "Premier relevé SNMP en cours…" : "Deuxième relevé attendu pour calculer le débit.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func rates(_ load: PortLoad) -> some View {
        HStack(alignment: .top, spacing: 12) {
            direction("Entrée", symbol: "arrow.down", bps: load.rate.inBitsPerSecond, percent: load.rate.inPercent, color: ResourceColors.primary)
            direction("Sortie", symbol: "arrow.up", bps: load.rate.outBitsPerSecond, percent: load.rate.outPercent, color: ResourceColors.secondary)
        }
    }

    private func direction(_ title: String, symbol: String, bps: Double?, percent: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                Text(ResourceFormat.bitsPerSecond(bps)).font(Theme.mono(14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            ResourceBar(percent: percent, height: 5)
            Text(percent.map { "\(ResourceFormat.percent($0)) de \(SNMPFormat.speed(mbps: iface.speedMbps))" } ?? "vitesse du lien inconnue")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errors(_ load: PortLoad) -> some View {
        let newErrors = load.rate.newErrors ?? 0
        let newDiscards = load.rate.newDiscards ?? 0
        return HStack(spacing: 12) {
            counter("Erreurs", total: load.counters.totalErrors, fresh: newErrors)
            counter("Rejets", total: load.counters.totalDiscards, fresh: newDiscards)
        }
    }

    private func counter(_ title: String, total: UInt64?, fresh: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text(total.map { SwitchText.grouped($0) } ?? "—").font(Theme.mono(12))
                if fresh > 0 {
                    Text("+\(SwitchText.grouped(fresh))")
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.critical)
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Theme.criticalSoft))
                        .help("Depuis le relevé précédent")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func counterNote(_ load: PortLoad) -> String {
        load.counters.width == .bits64 ? "ifHCInOctets (64\u{00A0}bits)" : "ifInOctets (32\u{00A0}bits, tour corrigé)"
    }
}

/// Panneau « Ports les plus chargés » d'un switch : cinq ports, % du lien et débit ; un clic
/// sélectionne le port sur la façade.
struct SwitchTopPorts: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    @ObservedObject var monitor: SNMPResourceMonitor
    let snapshot: SNMPSwitchSnapshot

    var body: some View {
        let top = monitor.topPorts(limit: 5)
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading
                    Spacer(minLength: 8)
                    system
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    system
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
            if top.isEmpty {
                Text(placeholder).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(top) { load in
                        row(load)
                        if load.id != top.last?.id { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 16) }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Ports les plus chargés").font(.system(size: 14, weight: .semibold)).fixedSize()
            Text("IF-MIB · relevé \(ResourceInterval.everyLabel(monitor.interval, capitalized: false))")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    /// Processeur et mémoire du switch, quand l'agent les donne.
    private var system: some View {
        HStack(spacing: 6) {
            if let cpu = monitor.processor?.load.total {
                Chip(text: "Processeur \(ResourceFormat.percent(cpu))", tone: ResourceColors.tone(cpu) == .success ? .neutral : ResourceColors.tone(cpu))
                    .help(monitor.processor?.source ?? "")
            }
            if let memory = monitor.memory?.memory {
                Chip(text: "Mémoire \(ResourceFormat.percent(memory.usedPercent))",
                     tone: ResourceColors.tone(memory.usedPercent) == .success ? .neutral : ResourceColors.tone(memory.usedPercent))
                    .help("\(ResourceFormat.memory(memory.usedBytes)) / \(ResourceFormat.memory(memory.totalBytes)) · \(monitor.memory?.source ?? "")")
            }
        }
        .fixedSize()
    }

    private var placeholder: String {
        if let error = monitor.error { return error }
        return monitor.lastPoll == nil ? "Premier relevé SNMP en cours…" : "Deuxième relevé attendu pour calculer les débits."
    }

    private func row(_ load: PortLoad) -> some View {
        let selected = store.selectedPort == load.index && store.current?.host == snapshot.host
        return Button {
            store.selectedHost = snapshot.host.description
            store.selectedPort = load.index
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(load.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(load.alias.isEmpty ? SNMPFormat.speed(mbps: load.speedMbps) : load.alias)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                .frame(width: 170, alignment: .leading)
                VStack(spacing: 3) {
                    bar(load.rate.inPercent, color: ResourceColors.primary)
                    bar(load.rate.outPercent, color: ResourceColors.secondary)
                }
                .frame(minWidth: 60, maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓\u{00A0}\(ResourceFormat.bitsPerSecond(load.rate.inBitsPerSecond))").font(Theme.mono(11))
                    Text("↑\u{00A0}\(ResourceFormat.bitsPerSecond(load.rate.outBitsPerSecond))").font(Theme.mono(11))
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 104, alignment: .trailing)
                Text(ResourceFormat.percent(load.rate.peakPercent))
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(ResourceColors.tone(load.rate.peakPercent) == .success ? Theme.text : ResourceColors.tone(load.rate.peakPercent).foreground)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(selected ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Note 33 : double-clic sur un port chargé → l'appareil branché.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.perform(.port(NavPortRef(host: snapshot.id, ifIndex: load.index)))
        })
        .contextMenu { OpenInMenu(object: .port(NavPortRef(host: snapshot.id, ifIndex: load.index))) }
        .help("\(load.name) · entrée \(ResourceFormat.percent(load.rate.inPercent)), sortie \(ResourceFormat.percent(load.rate.outPercent)) du lien de \(SNMPFormat.speed(mbps: load.speedMbps)) · cliquer pour le sélectionner")
    }

    private func bar(_ percent: Double?, color: Color) -> some View {
        ResourceBar(percent: percent, height: 5, color: (percent ?? 0) >= 75 ? ResourceColors.load(percent) : color)
    }
}

/// Branche les relevés de ressources du switch affiché : ils tournent tant que l'écran est visible.
struct SwitchResourceLifecycle: ViewModifier {
    let monitor: SNMPResourceMonitor

    func body(content: Content) -> some View {
        // Une tâche par switch : changer de switch arrête les relevés du précédent.
        content.task(id: monitor.host) {
            let current = monitor
            current.retain(autoStart: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            current.release()
        }
    }
}
