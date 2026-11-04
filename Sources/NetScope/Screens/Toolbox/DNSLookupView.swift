import NetScopeCore
import SwiftUI

@MainActor
final class ToolDNSModel: ObservableObject {
    @Published var query = ""
    @Published var type: DNSRecordType = .a
    /// Serveur choisi ; nil = résolveur du système.
    @Published var server: IPv4Address?
    @Published var customServer = ""
    @Published var useCustom = false
    @Published private(set) var isRunning = false
    @Published private(set) var result: DNSLookupResult?
    @Published var error: String?
    /// Numéro de la dernière requête : une réponse plus ancienne arrivée en retard est ignorée.
    private var generation = 0

    var effectiveServer: IPv4Address? { useCustom ? IPv4Address(customServer) : server }

    func run(store: ToolStore) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { error = "Saisir un nom ou une adresse."; return }
        if useCustom && IPv4Address(customServer) == nil {
            error = "Serveur DNS invalide (adresse IPv4 attendue)."
            return
        }
        let type = self.type
        let server = effectiveServer
        error = nil
        isRunning = true
        generation += 1
        let run = generation
        store.record(command: DNSLookup.command(for: text, type: type, server: server))
        Task {
            do {
                let result = try await DNSLookup.resolve(text, type: type, server: server)
                guard run == self.generation else { return }
                self.result = result
                let first = result.records.first.map { "\($0.typeLabel) \($0.value)" } ?? result.rcode
                store.record(ToolRecent(tool: .dns, target: text, summary: first,
                                        status: result.rcode == "NOERROR" ? .ok : .warning))
            } catch {
                guard run == self.generation else { return }
                self.result = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                store.record(ToolRecent(tool: .dns, target: text, summary: self.error ?? "Échec", status: .failure))
            }
            self.isRunning = false
        }
    }
}

/// Recherche DNS (A, AAAA, MX, PTR, TXT, NS, CNAME) sur le serveur choisi.
struct DNSLookupView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolDNSModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = DNSRecordTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Nom ou adresse") {
                    ToolTextField(placeholder: "WKS346.bureau.local, 10.182.122.111…", text: $model.query) { model.run(store: store) }
                }
                ToolLabeledField(label: "Serveur DNS") {
                    HStack(spacing: 6) {
                        serverMenu
                        if model.useCustom {
                            ToolTextField(placeholder: "9.9.9.9", text: $model.customServer,
                                          invalid: !model.customServer.isEmpty && IPv4Address(model.customServer) == nil)
                                .frame(width: 130)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                Button(model.isRunning ? "Résolution…" : "Résoudre") { model.run(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning)
            }
            HStack(spacing: 4) {
                ForEach(DNSRecordType.queryable) { type in
                    ToolChoiceChip(label: type.rawValue, isSelected: model.type == type) {
                        model.type = type
                        if !model.query.isEmpty { model.run(store: store) }
                    }
                }
                if model.result != nil {
                    Spacer(minLength: 8)
                    ToolColumnsMenu(model: table)
                }
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if let result = model.result {
                DNSRecordTable(rows: DNSRecordRow.rows(of: result), table: table)
                Text(result.summary).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                if let device = matchingDevice(result) {
                    Button("Ouvrir la fiche de \(device.displayName) →") { state.showDevice(device.id) }
                        .buttonStyle(.ghost)
                }
            } else if model.error == nil {
                Text("Sans serveur choisi, la requête passe par le résolveur de macOS (mêmes réponses que les applications). Une adresse IP en PTR est convertie en nom in-addr.arpa.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            // Nom d'hôte de l'appareil choisi s'il est un nom DNS valide, sinon son adresse en PTR.
            if model.query.isEmpty, let device = state.selectedDevice {
                if let host = device.hostname, host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil {
                    model.query = host
                } else {
                    model.query = device.ip.description
                    model.type = .ptr
                }
            }
        }
    }

    private var serverOptions: [(String, IPv4Address)] {
        var list: [(String, IPv4Address)] = []
        if let gateway = state.activeInterface?.gateway { list.append(("\(gateway) (passerelle)", gateway)) }
        for server in state.dnsServers where !list.contains(where: { $0.1 == server }) {
            list.append(("\(server) (DNS du réseau)", server))
        }
        for (name, text) in [("Cloudflare", "1.1.1.1"), ("Google", "8.8.8.8"), ("Quad9", "9.9.9.9")] {
            if let ip = IPv4Address(text), !list.contains(where: { $0.1 == ip }) { list.append(("\(text) (\(name))", ip)) }
        }
        return list
    }

    private var serverMenu: some View {
        let label = model.useCustom ? "Autre serveur" : (model.server.map { server in
            serverOptions.first { $0.1 == server }?.0 ?? server.description
        } ?? "Résolveur du système")
        return Menu {
            Button("Résolveur du système") { model.server = nil; model.useCustom = false }
            Divider()
            ForEach(serverOptions, id: \.1) { option in
                Button(option.0) { model.server = option.1; model.useCustom = false }
            }
            Divider()
            Button("Autre serveur…") { model.useCustom = true }
        } label: {
            Text(label).font(Theme.mono(12))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .frame(width: 230, height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func matchingDevice(_ result: DNSLookupResult) -> Device? {
        let values = result.records.map(\.value) + [model.query]
        return state.devices.first { device in
            values.contains(device.ip.description) || values.contains { value in
                guard let host = device.hostname, !host.isEmpty else { return false }
                return value.lowercased().hasPrefix(host.lowercased())
            }
        }
    }
}

// MARK: - Tableau des enregistrements

/// Ligne du tableau DNS : l'enregistrement, son rang dans la réponse, sa section et le serveur.
struct DNSRecordRow: Identifiable {
    let id: Int
    let record: DNSRecord
    /// « réponse » ; « autorité » quand la réponse est vide (SOA de la section d'autorité).
    let section: String
    let server: String

    var sortName: String { record.name.lowercased() }
    var sortType: String { record.typeLabel }
    var sortTTL: UInt32 { record.ttl }
    var sortValue: String { record.value.lowercased() }

    static func rows(of result: DNSLookupResult) -> [DNSRecordRow] {
        let section = result.answerCount == 0 ? "autorité" : "réponse"
        return result.records.enumerated().map { index, record in
            DNSRecordRow(id: index, record: record, section: section, server: result.serverLabel)
        }
    }
}

/// Enregistrements DNS (tableau standard « outils.dns », note 8) : nom, type, TTL, valeur ;
/// facultatives : rang dans la réponse, section, serveur interrogé.
struct DNSRecordTable: View {
    let rows: [DNSRecordRow]
    @ObservedObject var table: StandardTableModel<DNSRecordRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "ttl", title: "TTL"),
        StandardColumn(id: "valeur", title: "Valeur"),
        StandardColumn(id: "rang", title: "Rang dans la réponse", isDefaultVisible: false),
        StandardColumn(id: "section", title: "Section", isDefaultVisible: false),
        StandardColumn(id: "serveur", title: "Serveur interrogé", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<DNSRecordRow>] = [
        "nom": KeyPathComparator(\DNSRecordRow.sortName),
        "type": KeyPathComparator(\DNSRecordRow.sortType),
        "ttl": KeyPathComparator(\DNSRecordRow.sortTTL),
        "valeur": KeyPathComparator(\DNSRecordRow.sortValue),
        "rang": KeyPathComparator(\DNSRecordRow.id),
        "section": KeyPathComparator(\DNSRecordRow.section),
        "serveur": KeyPathComparator(\DNSRecordRow.server),
    ]

    /// Tri par défaut : l'ordre de la réponse (une chaîne CNAME reste lisible).
    @MainActor
    static func makeModel() -> StandardTableModel<DNSRecordRow> {
        StandardTableModel(id: "outils.dns", columns: columns, sortKeys: sortKeys, defaultSort: "rang")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucun enregistrement.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    ToolTableText(row.record.name).help(row.record.name)
                }
                .width(min: 120, ideal: 170)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    Chip(text: row.record.typeLabel, tone: .accent, mono: true)
                }
                .width(min: 50, ideal: 60)
                .customizationID("type")

                TableColumn("TTL", sortUsing: table.sort("ttl")) { row in
                    ToolTableText(String(row.record.ttl), alignment: .trailing)
                }
                .width(min: 44, ideal: 50)
                .customizationID("ttl")

                TableColumn("VALEUR", sortUsing: table.sort("valeur")) { row in
                    Text(row.record.value)
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(row.record.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 120, ideal: 220)
                .customizationID("valeur")

                TableColumn("RANG", sortUsing: table.sort("rang")) { row in
                    ToolTableText("\(row.id + 1)", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 36, ideal: 48)
                .customizationID("rang")
                .defaultVisibility(.hidden)

                TableColumn("SECTION", sortUsing: table.sort("section")) { row in
                    ToolTableText(row.section, mono: false, color: Theme.textSecondary)
                }
                .width(min: 60, ideal: 80)
                .customizationID("section")
                .defaultVisibility(.hidden)

                TableColumn("SERVEUR INTERROGÉ", sortUsing: table.sort("serveur")) { row in
                    ToolTableText(row.server, color: Theme.textSecondary).help(row.server)
                }
                .width(min: 90, ideal: 180)
                .customizationID("serveur")
                .defaultVisibility(.hidden)
            }
        }
    }
}
