import NetScopeCore
import SwiftUI

/// Détail de la fiche choisie : champs éditables, chronologie des changements, historiques IP et ports.
struct InvDetail: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let record: InvRecord
    let events: [InvEvent]
    let now: Date
    /// Site de la fiche (nil : site actif) : l'enregistrement va dans l'inventaire de ce site seulement.
    var siteKey: String?
    /// Sites où la même MAC est aussi vue (note 10 : signalée, jamais fusionnée).
    var otherSites: [String] = []
    /// Fiche créée par « Dupliquer » (site, clé) : l'écran la choisit.
    var onCreated: (String, String) -> Void = { _, _ in }

    @State private var draft: InvAnnotations?
    @State private var editing: InvManualMode?
    @State private var newTag = ""

    private var current: InvAnnotations { draft ?? record.annotations }
    private var isDirty: Bool { draft != nil && draft != record.annotations }

    /// Largeurs minimales des trois blocs : en dessous, ils passent sur deux rangées, puis en colonne,
    /// plutôt que d'écraser la chronologie en une colonne de quelques lettres.
    private static let sheetWidth: CGFloat = 330
    private static let timelineWidth: CGFloat = 290
    private static let historiesWidth: CGFloat = 430

    private var site: String { siteKey ?? model.siteKey }

    var body: some View {
        VStack(spacing: 14) {
            layouts
            InvAttachmentsPanel(record: record, siteKey: site)
        }
        .sheet(item: $editing) { mode in
            InvManualSheet(mode: mode, onDone: { key, site in onCreated(site, key) }, dismiss: { editing = nil })
        }
    }

    private var layouts: some View {
        ViewThatFits(in: .horizontal) {
            // Grande fenêtre : fiche, chronologie et historiques côte à côte.
            HStack(alignment: .top, spacing: 14) {
                sheet.frame(minWidth: Self.sheetWidth, idealWidth: Self.sheetWidth, maxWidth: .infinity)
                timeline.frame(minWidth: Self.timelineWidth, idealWidth: Self.timelineWidth, maxWidth: .infinity)
                histories(horizontal: false)
                    .frame(minWidth: Self.historiesWidth, idealWidth: Self.historiesWidth, maxWidth: .infinity)
            }
            // Fenêtre moyenne : fiche et chronologie, puis les deux historiques, côte à côte s'ils tiennent.
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    sheet.frame(minWidth: Self.sheetWidth, idealWidth: Self.sheetWidth, maxWidth: .infinity)
                    timeline.frame(minWidth: Self.timelineWidth, idealWidth: Self.timelineWidth, maxWidth: .infinity)
                }
                // Largeur idéale nulle : ce choix interne ne doit pas écarter l'agencement moyen.
                ViewThatFits(in: .horizontal) {
                    histories(horizontal: true)
                    histories(horizontal: false)
                }
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
            }
            // Très petite fenêtre : tout en colonne.
            VStack(spacing: 14) {
                sheet
                timeline.frame(maxWidth: .infinity)
                histories(horizontal: false)
            }
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
                        Text(record.displayName).font(Theme.panelTitle).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if record.isAwaitingScan {
                                InvPill(text: "Jamais scanné", foreground: Theme.textSecondary, background: Theme.neutralSoft)
                                    .help("Ajouté à la main\u{00A0}: il sera rapproché de l’appareil qu’un scan de ce site verra (même MAC, sinon même IP)")
                            } else {
                                let status = record.status(now: now)
                                let colors = InvStyle.status(status)
                                InvPill(text: status.label, foreground: colors.0, background: colors.1)
                            }
                            // Fabricant et nom d'hôte sur deux lignes au besoin plutôt que coupés.
                            Text([record.vendorLabel, record.hostname].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                }
                if record.isManual || !otherSites.isEmpty {
                    InvFlowLayout(spacing: 6) {
                        if let manual = record.manual {
                            InvPill(text: "AJOUTÉ À LA MAIN", foreground: Theme.accentStrong, background: InvStyle.infoSoft, size: 9.5)
                                .help("Ajouté à la main le \(InvFormat.day(manual.created))"
                                      + (manual.matched.map { ", rapproché d’un appareil scanné le \(InvFormat.day($0))" } ?? ", pas encore vu par un scan"))
                        }
                        if !otherSites.isEmpty {
                            InvPill(text: "MÊME MAC\u{00A0}: " + otherSites.joined(separator: ", "), foreground: Theme.warning,
                                    background: Theme.warningSoft, size: 9.5)
                                .help("Cette MAC est aussi dans l’inventaire de «\u{00A0}\(otherSites.joined(separator: "\u{00A0}», «\u{00A0}"))\u{00A0}»\u{00A0}: fiches distinctes, jamais fusionnées.")
                        }
                    }
                    .padding(.top, -6)
                }
                if let state = current.hardware?.warranty(now: now), state.isAlert {
                    Label(state.label + (current.hardware?.warrantyEnd.map { " · fin le \(InvFormat.day($0))" } ?? ""),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.warning)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft))
                }
                // « Fiche complète » sur la ligne de l'adresse : le nom garde toute la largeur.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        addressLine.fixedSize()
                        Spacer(minLength: 0)
                        fullSheetButton
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        addressLine
                        fullSheetButton.padding(.leading, -8)
                    }
                }
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

                InvWarrantyFields(hardware: Binding(get: { current.hardware ?? InvHardware() }, set: { value in
                    var updated = current
                    updated.hardware = value
                    draft = updated
                }), now: now)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Étiquettes").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    InvFlowLayout(spacing: 6) {
                        ForEach(availableTags, id: \.self) { tag in
                            // Bouton bascule natif : enfoncé et teinté d'accent quand l'étiquette est posée.
                            Toggle(tag, isOn: Binding(get: { current.tags.contains(tag) }, set: { on in
                                var updated = current
                                updated.tags.removeAll { $0 == tag }
                                if on { updated.tags.append(tag) }
                                draft = updated
                            }))
                            .toggleStyle(.button)
                            .controlSize(.small)
                        }
                        // Étiquette libre : ajoutée au brouillon (filtrable dans l'Inventaire).
                        HStack(spacing: 4) {
                            TextField("Nouvelle étiquette", text: $newTag, prompt: Text("Nouvelle…"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .frame(width: 96)
                                .onSubmit(addTag)
                            Button(action: addTag) { Image(systemName: "plus") }
                                .controlSize(.small)
                                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                                .help("Ajouter cette étiquette à la fiche")
                                .accessibilityLabel("Ajouter l’étiquette")
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
                        guard var draft, isDirty else {
                            model.show("Aucune modification à enregistrer")
                            return
                        }
                        let site = siteKey ?? model.siteKey
                        draft.hardware = draft.hardware?.cleaned
                        model.setAnnotations(draft, for: record.key, site: site)
                        // Le nom saisi suit l'appareil dans les autres écrans (appareils du site actif seulement).
                        if site == model.siteKey, state.device(withID: record.ip.description)?.mac == record.mac {
                            state.setCustomName(draft.customName, for: record.ip.description)
                        }
                        let name = model.inventory(for: site).record(record.key)?.displayName ?? record.displayName
                        model.show("Fiche enregistrée\u{00A0}: \(name)" + (site == model.siteKey ? "" : " (site «\u{00A0}\(SiteModel.shared.name(forKey: site))\u{00A0}»)"))
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

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        var updated = current
        if !updated.tags.contains(where: { $0.lowercased() == tag.lowercased() }) { updated.tags.append(tag) }
        draft = updated
        newTag = ""
    }

    private var addressLine: some View {
        Text("\(record.hasAddress ? record.ip.description : "Sans adresse IP") · \(record.mac?.formatted(.upperColon) ?? "MAC inconnue")")
            .font(Theme.mono(12)).foregroundStyle(Theme.neutralText).textSelection(.enabled)
    }

    @ViewBuilder
    private var fullSheetButton: some View {
        HStack(spacing: 0) {
            if record.isManual {
                Button("Modifier…") { editing = .edit(site: site, key: record.key) }.buttonStyle(.ghost)
                    .help("Modifier l’appareil ajouté à la main (IP, MAC, switch et port tant qu’aucun scan ne l’a vu)")
            }
            Button("Dupliquer") {
                guard let copy = model.duplicate(record.key, site: site) else { return }
                model.show("Copie créée\u{00A0}: \(model.inventory(for: site).record(copy)?.displayName ?? "")")
                onCreated(site, copy)
            }
            .buttonStyle(.ghost)
            .help("Créer une fiche «\u{00A0}Ajouté à la main\u{00A0}» avec les mêmes champs, sans IP ni MAC")
            // Fiche complète : appareils du scan du site actif seulement (la même IP d'un autre site n'est pas lui).
            if record.hasAddress, (siteKey ?? model.siteKey) == model.siteKey, state.device(withID: record.ip.description) != nil {
                Button("Fiche complète") { state.showDevice(record.ip.description) }.buttonStyle(.ghost)
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
        }
    }

    private var availableTags: [String] {
        var tags = InvStyle.defaultTags
        let used = model.inventory(for: site).allTags + current.tags
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
                                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 2))
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

    private func histories(horizontal: Bool) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            : AnyLayout(VStackLayout(spacing: 14))
        // Côte à côte : largeurs qui laissent voir toutes les colonnes des tableaux sans défilement.
        return layout {
            ipHistory
                .frame(minWidth: horizontal ? 360 : nil, idealWidth: horizontal ? 360 : nil, maxWidth: .infinity)
            portHistory
                .frame(minWidth: horizontal ? 430 : nil, idealWidth: horizontal ? 430 : nil, maxWidth: .infinity)
        }
    }

    private var ipHistory: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Historique des IP")
                if record.ipHistory.isEmpty {
                    Text("Aucune adresse\u{00A0}: appareil ajouté à la main sans IP. Elle sera relevée par le scan qui le reconnaîtra.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                InvIPHistoryTable(rows: record.ipHistory.enumerated().map { index, span in
                    InvIPHistoryRow(id: index, ip: span.ip, from: span.from, until: untilDate(span.to),
                                    untilLabel: until(span.to))
                })
                }
            }
        }
    }

    private var portHistory: some View {
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
                    Button("Voir le port actuel") { state.showSwitchPort(switchName: record.switchName, port: record.switchPort) }.buttonStyle(.ghost)
                    if record.hasAddress {
                        Button("Ping continu") { state.sendToPing(record.ip.description) }.buttonStyle(.ghost)
                    }
                }
                .padding(.leading, -8)
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
            .width(min: 76, ideal: 78)
            .customizationID("du")

            TableColumn("AU", sortUsing: table.sort("au")) { row in
                InvHistoryMetrics.text(row.untilLabel)
            }
            .width(min: 76, ideal: 78)
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
            .width(min: 108, ideal: 112)
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
            .width(min: 76, ideal: 78)
            .customizationID("du")

            TableColumn("AU", sortUsing: table.sort("au")) { row in
                InvHistoryMetrics.text(row.untilLabel)
            }
            .width(min: 76, ideal: 78)
            .customizationID("au")
        }
        .standardTableStyle()
        .frame(height: InvHistoryMetrics.height(rows: rows.count, rowHeight: Self.rowHeight))
        .scrollIndicators(rows.count > InvHistoryMetrics.maxVisibleRows ? .automatic : .never, axes: .vertical)
    }
}
