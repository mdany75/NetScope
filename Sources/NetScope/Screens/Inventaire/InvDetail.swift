import NetScopeCore
import SwiftUI

/// Détail de la fiche choisie : champs éditables, chronologie des changements, historiques IP et ports.
struct InvDetail: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let record: InvRecord
    let events: [InvEvent]
    let now: Date

    @State private var draft: InvAnnotations?

    private var current: InvAnnotations { draft ?? record.annotations }
    private var isDirty: Bool { draft != nil && draft != record.annotations }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sheet.frame(maxWidth: .infinity)
            timeline.frame(maxWidth: .infinity)
            histories.frame(minWidth: 410, maxWidth: .infinity)
        }
    }

    private func binding(_ path: WritableKeyPath<InvAnnotations, String>) -> Binding<String> {
        Binding(get: { current[keyPath: path] }, set: { value in
            var updated = current
            updated[keyPath: path] = value
            draft = updated
        })
    }

    // MARK: Fiche éditable

    private var sheet: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.neutralSoft)
                        Image(systemName: InvStyle.symbol(record.type)).font(.system(size: 17)).foregroundStyle(Theme.neutralText)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName).font(Theme.panelTitle).lineLimit(1)
                        HStack(spacing: 6) {
                            let status = record.status(now: now)
                            let colors = InvStyle.status(status)
                            InvPill(text: status.label, foreground: colors.0, background: colors.1)
                            Text([record.vendorLabel, record.hostname].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if state.device(withID: record.ip.description) != nil {
                        Button("Fiche complète") { state.showDevice(record.ip.description) }.buttonStyle(.ghost)
                    }
                }
                Text("\(record.ip.description) · \(record.mac?.formatted(.upperColon) ?? "MAC inconnue")")
                    .font(Theme.mono(12)).foregroundStyle(Theme.neutralText).textSelection(.enabled)
                    .padding(.top, -6)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        InvField(label: "Nom", text: Binding(get: { current.customName ?? "" }, set: { value in
                            var updated = current
                            updated.customName = value
                            draft = updated
                        }), placeholder: record.hostname ?? "")
                        typePicker
                    }
                    GridRow {
                        InvField(label: "Local", text: binding(\.location))
                        InvField(label: "Prise murale", text: binding(\.wallJack))
                    }
                    GridRow {
                        InvField(label: "Responsable", text: binding(\.owner))
                        InvField(label: "N° d’actif", text: binding(\.assetNumber))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Étiquettes").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    InvFlowLayout(spacing: 6) {
                        ForEach(availableTags, id: \.self) { tag in
                            let on = current.tags.contains(tag)
                            Button {
                                var updated = current
                                if on { updated.tags.removeAll { $0 == tag } } else { updated.tags.append(tag) }
                                draft = updated
                            } label: {
                                Text(tag)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(on ? Theme.accentStrong : Theme.text)
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .background(Capsule().fill(on ? Theme.accentSoft : Theme.panel))
                                    .overlay(Capsule().strokeBorder(on ? Theme.accent : Theme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    TextEditor(text: binding(\.notes))
                        .font(Theme.small)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
                }

                HStack(spacing: 8) {
                    Button {
                        guard let draft, isDirty else {
                            model.show("Aucune modification à enregistrer")
                            return
                        }
                        model.setAnnotations(draft, for: record.key)
                        // Le nom saisi suit l'appareil dans les autres écrans.
                        if state.device(withID: record.ip.description)?.mac == record.mac {
                            state.setCustomName(draft.customName, for: record.ip.description)
                        }
                        model.show("Fiche enregistrée : \(model.record(record.key)?.displayName ?? record.displayName)")
                        self.draft = nil
                    } label: { Label("Enregistrer", systemImage: "checkmark") }
                        .buttonStyle(.primary)
                    Button("Annuler") { draft = nil }.buttonStyle(.secondary).disabled(!isDirty)
                    Text(isDirty ? "Modifications non enregistrées" : "Fiche à jour")
                        .font(.system(size: 12, weight: isDirty ? .semibold : .regular))
                        .foregroundStyle(isDirty ? Theme.warning : Theme.textSecondary)
                }
            }
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            Picker("", selection: Binding(get: { current.customType ?? record.detectedType }, set: { value in
                var updated = current
                updated.customType = value == record.detectedType ? nil : value
                draft = updated
            })) {
                ForEach(DeviceType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(height: 30)
        }
    }

    private var availableTags: [String] {
        var tags = InvStyle.defaultTags
        let used = model.store.records.values.flatMap(\.annotations.tags) + current.tags
        for tag in used where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    // MARK: Chronologie

    private var timeline: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Chronologie des changements",
                              subtitle: "\(events.count) événement\(events.count > 1 ? "s" : "")") { EmptyView() }
                if events.isEmpty {
                    Text("Aucun événement enregistré pour cet appareil.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.suffix(12).enumerated()), id: \.element.id) { index, event in
                        let colors = InvStyle.kind(event.kind)
                        let isLast = index == min(events.count, 12) - 1
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(colors.dot).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                                .overlay(Circle().strokeBorder(colors.dot, lineWidth: 1).padding(-1))
                                .padding(.top, 2)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(InvFormat.day(event.date)).font(Theme.mono(12, weight: .semibold))
                                    Text(event.kind.label.uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                        .kerning(0.3)
                                        .foregroundStyle(colors.fg)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(colors.bg))
                                }
                                Text(event.title).font(Theme.bodySemibold).fixedSize(horizontal: false, vertical: true)
                                Text(event.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.bottom, isLast ? 0 : 14)
                        }
                        .background(alignment: .topLeading) {
                            if !isLast {
                                Rectangle().fill(Theme.border).frame(width: 2).padding(.leading, 6).padding(.top, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Historiques

    private var histories: some View {
        VStack(spacing: 14) {
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Historique des IP")
                    InvIPHistoryTable(rows: record.ipHistory.enumerated().map { index, span in
                        InvIPHistoryRow(id: index, ip: span.ip, from: span.from, until: untilDate(span.to),
                                        untilLabel: until(span.to))
                    })
                }
            }
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Historique des ports de switch")
                    if record.portHistory.isEmpty {
                        Text("Port de switch inconnu : il sera relevé par SNMP (écran Switchs et ports).")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        InvPortHistoryTable(rows: record.portHistory.enumerated().map { index, span in
                            InvPortHistoryRow(id: index, switchName: span.switchName, port: span.port, vlan: span.vlan,
                                              from: span.from, until: untilDate(span.to), untilLabel: until(span.to))
                        })
                    }
                    HStack(spacing: 4) {
                        Button("Voir le port actuel") { state.open(.switchs) }.buttonStyle(.ghost)
                        Button("Ping continu") { state.sendToPing(record.ip.description) }.buttonStyle(.ghost)
                    }
                    .padding(.leading, -8)
                }
            }
        }
    }

    private func until(_ date: Date?) -> String {
        guard let date else { return record.isGone(now: now) ? InvFormat.day(record.lastSeen) : "Aujourd’hui" }
        return InvFormat.day(date)
    }

    /// Date de fin pour le tri : la période en cours est la plus récente.
    private func untilDate(_ date: Date?) -> Date {
        guard let date else { return record.isGone(now: now) ? record.lastSeen : .distantFuture }
        return date
    }
}

// MARK: - Historiques (tableaux standard, note 8)

struct InvIPHistoryRow: Identifiable {
    let id: Int
    let ip: IPv4Address
    let from: Date
    /// Fin de la période ; `.distantFuture` pour l'adresse actuelle.
    let until: Date
    let untilLabel: String
}

struct InvPortHistoryRow: Identifiable {
    let id: Int
    let switchName: String
    let port: String
    let vlan: Int?
    let from: Date
    let until: Date
    let untilLabel: String

    var label: String { "\(switchName) · \(port)" }
    var sortVLAN: Int { vlan ?? .max }
}

/// Mesures communes des petits tableaux d'historique (hauteur fixe dans l'écran qui défile).
enum InvHistoryMetrics {
    static let headerHeight: CGFloat = 40
    static let maxVisibleRows = 6

    static func height(rows: Int, rowHeight: CGFloat) -> CGFloat {
        headerHeight + CGFloat(min(max(rows, 1), maxVisibleRows)) * rowHeight
    }

    static func text(_ text: String) -> some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.neutralText).monospacedDigit().lineLimit(1)
    }
}

/// Historique des IP d'une fiche : IP, Du, Au (la plus récente d'abord).
struct InvIPHistoryTable: View {
    let rows: [InvIPHistoryRow]
    @StateObject private var table = Self.makeModel()

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ip", title: "IP", isRequired: true),
        StandardColumn(id: "du", title: "Du"),
        StandardColumn(id: "au", title: "Au"),
    ]

    static let sortKeys: [String: KeyPathComparator<InvIPHistoryRow>] = [
        "ip": KeyPathComparator(\InvIPHistoryRow.ip),
        "du": KeyPathComparator(\InvIPHistoryRow.from, order: .reverse),
        "au": KeyPathComparator(\InvIPHistoryRow.until, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<InvIPHistoryRow> {
        StandardTableModel(id: "inventaire.historiqueIP", columns: columns, sortKeys: sortKeys, defaultSort: "du")
    }

    private static let rowHeight: CGFloat = 28

    var body: some View {
        Table(rows.sorted(using: table.sortOrder), sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("IP", sortUsing: table.sort("ip")) { row in
                Text(row.ip.description).font(Theme.mono(11.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .frame(height: 20)
            }
            .width(min: 90, ideal: 112)
            .customizationID("ip")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("DU", sortUsing: table.sort("du")) { row in
                InvHistoryMetrics.text(InvFormat.day(row.from))
            }
            .width(min: 70, ideal: 74)
            .customizationID("du")

            TableColumn("AU", sortUsing: table.sort("au")) { row in
                InvHistoryMetrics.text(row.untilLabel)
            }
            .width(min: 62, ideal: 74)
            .customizationID("au")
        }
        .standardTableStyle()
        .frame(height: InvHistoryMetrics.height(rows: rows.count, rowHeight: Self.rowHeight))
        .scrollIndicators(rows.count > InvHistoryMetrics.maxVisibleRows ? .automatic : .never, axes: .vertical)
    }
}

/// Historique des ports de switch d'une fiche : Switch / port, VLAN, Du, Au (le plus récent d'abord).
struct InvPortHistoryTable: View {
    let rows: [InvPortHistoryRow]
    @StateObject private var table = Self.makeModel()

    static let columns: [StandardColumn] = [
        StandardColumn(id: "switch", title: "Switch / port", isRequired: true),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "du", title: "Du"),
        StandardColumn(id: "au", title: "Au"),
    ]

    static let sortKeys: [String: KeyPathComparator<InvPortHistoryRow>] = [
        "switch": KeyPathComparator(\InvPortHistoryRow.label, comparator: .localizedStandard),
        "vlan": KeyPathComparator(\InvPortHistoryRow.sortVLAN),
        "du": KeyPathComparator(\InvPortHistoryRow.from, order: .reverse),
        "au": KeyPathComparator(\InvPortHistoryRow.until, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<InvPortHistoryRow> {
        StandardTableModel(id: "inventaire.historiquePorts", columns: columns, sortKeys: sortKeys, defaultSort: "du")
    }

    /// Deux lignes par cellule : le switch, puis le port (le panneau est étroit).
    private static let rowHeight: CGFloat = 38

    var body: some View {
        Table(rows.sorted(using: table.sortOrder), sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("SWITCH / PORT", sortUsing: table.sort("switch")) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.switchName).font(Theme.mono(11.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(row.port).font(Theme.mono(11)).foregroundStyle(Theme.neutralText).lineLimit(1)
                }
                .frame(height: 30)
                .help(row.label)
            }
            .width(min: 90, ideal: 100)
            .customizationID("switch")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("VLAN", sortUsing: table.sort("vlan")) { row in
                if let vlan = row.vlan {
                    Chip(text: "\(vlan)", mono: true)
                } else {
                    Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
                }
            }
            .width(min: 38, ideal: 40)
            .customizationID("vlan")

            TableColumn("DU", sortUsing: table.sort("du")) { row in
                InvHistoryMetrics.text(InvFormat.day(row.from))
            }
            .width(min: 70, ideal: 72)
            .customizationID("du")

            TableColumn("AU", sortUsing: table.sort("au")) { row in
                InvHistoryMetrics.text(row.untilLabel)
            }
            .width(min: 70, ideal: 74)
            .customizationID("au")
        }
        .standardTableStyle()
        .frame(height: InvHistoryMetrics.height(rows: rows.count, rowHeight: Self.rowHeight))
        .scrollIndicators(rows.count > InvHistoryMetrics.maxVisibleRows ? .automatic : .never, axes: .vertical)
    }
}
