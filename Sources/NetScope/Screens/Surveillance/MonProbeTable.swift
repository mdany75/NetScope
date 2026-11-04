import NetScopeCore
import SwiftUI

/// Filtre de la liste des sondes.
enum MonProbeFilter: String, CaseIterable {
    case all, warning, down, paused

    var title: String {
        switch self {
        case .all: return "Toutes"
        case .warning: return "En alerte"
        case .down: return "Hors ligne"
        case .paused: return "Inactives"
        }
    }

    var dot: Color? {
        switch self {
        case .all: return nil
        case .warning: return Theme.warning
        case .down: return Theme.critical
        case .paused: return Theme.textTertiary
        }
    }
}

/// Largeurs des colonnes du tableau des sondes (la colonne « Sonde · cible » prend le reste).
private enum MonColumns {
    static let active: CGFloat = 46
    static let type: CGFloat = 86
    static let interval: CGFloat = 80
    static let state: CGFloat = 80
    static let value: CGFloat = 150
    static let uptime: CGFloat = 176
    static let rowHeight: CGFloat = 40
}

/// Panneau « Sondes » : filtres, recherche, tableau et légende.
struct MonProbeTable: View {
    @ObservedObject private var store = MonStore.shared
    @State private var filter: MonProbeFilter = .all
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            columns
            let rows = filtered
            if rows.isEmpty {
                Text(store.probes.isEmpty ? "Aucune sonde. Créez-en une avec «\u{00A0}Nouvelle sonde\u{00A0}»."
                                          : "Aucune sonde ne correspond aux filtres actifs.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    VStack(spacing: 0) {
                        ForEach(rows) { probe in
                            MonProbeRow(probe: probe, isSelected: probe.id == store.selectedProbe?.id)
                        }
                    }
                }
            }
            footer
        }
        .monPanel()
    }

    private var filtered: [MonProbe] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.probes.filter { probe in
            switch filter {
            case .all: break
            case .warning: if store.state(of: probe) != .warning { return false }
            case .down: if store.state(of: probe) != .down { return false }
            case .paused: if probe.isEnabled { return false }
            }
            guard !q.isEmpty else { return true }
            let text = [probe.name, probe.target, probe.subtitle, probe.kind.label, probe.kind.shortLabel].joined(separator: " ")
            return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func count(_ filter: MonProbeFilter) -> Int {
        switch filter {
        case .all: return store.probes.count
        case .warning: return store.warningCount
        case .down: return store.downCount
        case .paused: return store.pausedCount
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MonHeading("Sondes").padding(.trailing, 6)
            ForEach(MonProbeFilter.allCases, id: \.self) { item in
                MonFilterChip(title: item.title, count: count(item), dot: item.dot, isOn: filter == item) { filter = item }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                TextField("", text: $query, prompt: Text("Nom, IP, type…").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.small)
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            heading("Actif").frame(width: MonColumns.active, alignment: .leading).padding(.leading, 12)
            heading("Sonde · cible").padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
            heading("Type").padding(.horizontal, 6).frame(width: MonColumns.type, alignment: .leading)
            heading("Intervalle").padding(.horizontal, 6).frame(width: MonColumns.interval, alignment: .leading)
            heading("État").padding(.horizontal, 6).frame(width: MonColumns.state, alignment: .leading)
            heading("Dernière valeur").padding(.horizontal, 6).frame(width: MonColumns.value, alignment: .leading)
            heading("Disponibilité 24 h").padding(.leading, 6).frame(width: MonColumns.uptime, alignment: .leading)
                .padding(.trailing, 12)
        }
        .frame(height: 32)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.3)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 14) {
            legend(Theme.success, "Disponible")
            legend(Theme.warning, "Seuil dépassé")
            legend(Theme.critical, "Hors ligne")
            legend(Theme.border, "Aucune donnée", stroke: true)
            Spacer(minLength: 8)
            Text("\(filtered.count) affichées sur \(MonText.plural(store.probes.count, "sonde", "sondes"))")
                .lineLimit(1)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func legend(_ color: Color, _ text: String, stroke: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color)
                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(stroke ? Theme.borderStrong : .clear))
                .frame(width: 8, height: 10)
            Text(text).lineLimit(1).fixedSize()
        }
    }
}

/// Une ligne du tableau des sondes.
private struct MonProbeRow: View {
    @ObservedObject private var store = MonStore.shared
    let probe: MonProbe
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let state = store.state(of: probe)
        let now = store.now
        HStack(spacing: 0) {
            MonSwitch(isOn: Binding(get: { probe.isEnabled }, set: { store.setEnabled($0, for: probe.id) }),
                      label: "Sonde \(probe.name) active")
                .frame(width: MonColumns.active, alignment: .leading)
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(probe.name)
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(targetLabel)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(probe.name)\n\(targetLabel)")
            Text(probe.kind.shortLabel)
                .font(Theme.captionSemibold)
                .foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.neutralSoft))
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(width: MonColumns.type, alignment: .leading)
            Text(MonProbe.intervalLabel(probe.interval))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.neutralText)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: MonColumns.interval, alignment: .leading)
            RegPill(text: MonText.label(state), tone: MonText.tone(state))
                .padding(.horizontal, 6)
                .frame(width: MonColumns.state, alignment: .leading)
            Text(store.lastValue(of: probe))
                .font(Theme.mono(11, weight: state == .down || state == .warning ? .semibold : .regular))
                .foregroundStyle(state == .down ? Theme.critical : state == .warning ? Theme.warning : Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .frame(width: MonColumns.value, alignment: .leading)
            MonUptimeBar(slots: store.history.slots(probe: probe.id, now: now),
                         availability: store.history.availability(probe: probe.id, now: now),
                         enabled: probe.isEnabled, name: probe.name)
                .padding(.leading, 6)
                .frame(width: MonColumns.uptime, alignment: .leading)
                .padding(.trailing, 12)
        }
        .frame(height: MonColumns.rowHeight)
        .background(isSelected ? Theme.accentSoft : hovering ? Theme.panelMuted : Theme.panel)
        .opacity(probe.isEnabled ? 1 : 0.62)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = probe.id
            store.toast = nil
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// « 10.182.122.1 · FortiGate-60F », « intranet.local @ 10.182.122.1 ».
    private var targetLabel: String {
        var label = probe.target.isEmpty ? "[À COMPLÉTER]" : probe.target
        if probe.kind == .dns, let server = probe.dnsServer, !server.isEmpty { label += " @ \(server)" }
        if !probe.subtitle.isEmpty { label += " · \(probe.subtitle)" }
        return label
    }
}

/// Barre de disponibilité 24 h : une case par heure, puis le pourcentage.
struct MonUptimeBar: View {
    let slots: [MonSlot]
    let availability: Double?
    var enabled = true
    var name = ""

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(enabled ? color(slot) : Theme.borderStrong)
                        .frame(width: 3, height: 14)
                }
            }
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.neutralText)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disponibilité sur 24 h de \(name) : \(label)")
    }

    private var label: String {
        guard let availability else { return "—" }
        return ToolFormat.decimal(availability) + "\u{00A0}%"
    }

    private func color(_ slot: MonSlot) -> Color {
        switch slot {
        case .ok: return Theme.success
        case .warning: return Theme.warning
        case .down: return Theme.critical
        case .none: return Theme.border
        }
    }
}

/// Petit interrupteur du croquis (30 × 18), accent quand actif.
struct MonSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Color(hex: 0x9CA3AF))
                Circle().fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "activée" : "désactivée")
    }
}
