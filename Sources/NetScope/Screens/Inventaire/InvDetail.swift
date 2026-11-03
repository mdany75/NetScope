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
            histories.frame(maxWidth: .infinity)
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
                    miniTable(headers: ["IP", "Du", "Au"],
                              rows: record.ipHistory.reversed().map { span in
                                  [span.ip.description, InvFormat.day(span.from), until(span.to)]
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
                        miniTable(headers: ["Switch / port", "VLAN", "Du", "Au"],
                                  rows: record.portHistory.reversed().map { span in
                                      [span.label, span.vlan.map { "VLAN \($0)" } ?? "—", InvFormat.day(span.from), until(span.to)]
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

    private func miniTable(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(headers, id: \.self) { title in
                    Text(title.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                        .frame(height: 24, alignment: .leading)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                        Group {
                            if headers[index] == "VLAN" {
                                Text(value).font(Theme.caption).foregroundStyle(Theme.neutralText)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.neutralSoft))
                            } else {
                                Text(value)
                                    .font(index == 0 ? Theme.mono(11.5, weight: .semibold) : Theme.mono(11))
                                    .foregroundStyle(index == 0 ? Theme.text : Theme.neutralText)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(minHeight: 28, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
