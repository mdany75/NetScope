import NetScopeCore
import SwiftUI

/// Vue de l'outil DNS : une recherche, la comparaison de plusieurs serveurs côte à côte, ou la
/// propagation (même question aux résolveurs publics, écarts signalés).
enum DNSToolMode: String, CaseIterable, Identifiable {
    case lookup, compare, propagation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lookup: return "Recherche"
        case .compare: return "Comparer"
        case .propagation: return "Propagation"
        }
    }
}

/// Serveur proposé pour la comparaison (nil = résolveur du système).
struct DNSServerOption: Identifiable, Hashable {
    let name: String
    let address: IPv4Address?
    var region: String? = nil

    var id: String { address?.description ?? "système" }
    var label: String { address.map { "\(name) · \($0)" } ?? name }
}

@MainActor
final class ToolDNSModel: ObservableObject {
    @Published var query = ""
    @Published var type: DNSRecordType = .a
    /// Serveur choisi ; nil = résolveur du système.
    @Published var server: IPv4Address?
    @Published var customServer = ""
    @Published var useCustom = false
    @Published var mode: DNSToolMode = .lookup
    /// Serveurs cochés pour la comparaison (identifiants de `DNSServerOption`).
    @Published var compareSelection: Set<String> = ["système", "1.1.1.1", "8.8.8.8", "9.9.9.9"]
    @Published var compareCustom = ""
    @Published private(set) var isRunning = false
    @Published private(set) var result: DNSLookupResult?
    @Published private(set) var comparison: DNSComparison?
    @Published private(set) var propagation: DNSComparison?
    @Published var error: String?
    /// Numéro de la dernière requête : une réponse plus ancienne arrivée en retard est ignorée.
    private var generation = 0

    init() {
        // Démonstration (--demo) : résultats fixes (DevTools/MailDNSDemo.swift), aucune requête.
        if Launcher.isDemo {
            let demo = MailDNSDemo.dnsInitialState()
            query = demo.query
            type = demo.type
            mode = demo.mode
            result = demo.result
            comparison = demo.comparison
            propagation = demo.propagation
        }
    }

    var effectiveServer: IPv4Address? { useCustom ? IPv4Address(customServer) : server }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        let target = query.isEmpty ? "<nom>" : query
        switch mode {
        case .lookup: return DNSLookup.command(for: target, type: type, server: effectiveServer)
        case .compare:
            let servers = compareSelection.filter { $0 != "système" }.sorted().prefix(3).map { "@\($0)" }.joined(separator: " ")
            return "dig \(type.rawValue) \(target) " + (servers.isEmpty ? "(plusieurs serveurs)" : servers + " …")
        case .propagation: return "dig \(type.rawValue) \(target) @<\(DNSPublicResolver.propagation.count) résolveurs publics>"
        }
    }

    func run(store: ToolStore, compareOptions: [DNSServerOption]) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { error = "Saisir un nom ou une adresse."; return }
        if mode == .lookup && useCustom && IPv4Address(customServer) == nil {
            error = "Serveur DNS invalide (adresse IPv4 attendue)."
            return
        }
        var servers = compareOptions.filter { compareSelection.contains($0.id) }
        if mode == .compare {
            let custom = compareCustom.trimmingCharacters(in: .whitespaces)
            if !custom.isEmpty {
                guard let ip = IPv4Address(custom) else { error = "Serveur DNS invalide (adresse IPv4 attendue)."; return }
                if !servers.contains(where: { $0.address == ip }) { servers.append(DNSServerOption(name: "Autre", address: ip)) }
            }
            guard servers.count >= 2 else { error = "Cocher au moins deux serveurs à comparer."; return }
        }
        let type = self.type
        let server = effectiveServer
        let mode = self.mode
        error = nil
        isRunning = true
        generation += 1
        let run = generation
        store.record(command: command)
        Task {
            switch mode {
            case .lookup:
                do {
                    let result = Launcher.isDemo ? MailDNSDemo.lookup(text, type: type)
                                                        : try await DNSLookup.resolve(text, type: type, server: server)
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
            case .compare:
                let comparison = Launcher.isDemo
                    ? MailDNSDemo.comparison(text, type: type, servers: servers.map { ($0.name, $0.address, $0.region) })
                    : await DNSLookup.compare(text, type: type, servers: servers.map { ($0.name, $0.address, $0.region) })
                guard run == self.generation else { return }
                self.comparison = comparison
                store.record(ToolRecent(tool: .dns, target: "\(text) \(type.rawValue)", summary: comparison.summary,
                                        status: comparison.isConsistent ? .ok : .warning, title: "Comparaison DNS"))
            case .propagation:
                let propagation = Launcher.isDemo ? MailDNSDemo.propagation(text, type: type)
                                                         : await DNSLookup.propagation(text, type: type)
                guard run == self.generation else { return }
                self.propagation = propagation
                store.record(ToolRecent(tool: .dns, target: "\(text) \(type.rawValue)", summary: propagation.summary,
                                        status: propagation.isConsistent ? .ok : .warning, title: "Propagation DNS"))
            }
            self.isRunning = false
        }
    }
}

/// Recherche DNS (A, AAAA, MX, PTR, TXT, NS, CNAME, SOA, SRV, CAA, DNSKEY, DS) sur le serveur
/// choisi, comparaison de serveurs et propagation.
struct DNSLookupView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolDNSModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = DNSRecordTable.makeModel()
    @StateObject private var propagationTable = DNSPropagationTable.makeModel()

    /// Types du sélecteur segmenté ; les autres passent par le menu « Autres ».
    private static let mainTypes: [DNSRecordType] = [.a, .aaaa, .mx, .txt, .ns, .cname, .ptr]
    private static let moreTypes: [DNSRecordType] = DNSRecordType.queryable.filter { !mainTypes.contains($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Nom ou adresse") {
                    ToolTextField(placeholder: "exemple.ca, WKS346.bureau.local, 10.182.122.111…", text: $model.query) { run() }
                        .frame(minWidth: 180)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if model.mode == .lookup {
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
                    }
                    Button(model.isRunning ? runningLabel : runLabel) { run() }
                        .buttonStyle(.primary)
                        .disabled(model.isRunning)
                        .fixedSize()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    typeSegments
                    moreTypes
                    Spacer(minLength: 8)
                    modePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        typeSegments
                        moreTypes
                    }
                    modePicker
                }
                // Petite fenêtre : le menu « Autres » passe à côté de la vue.
                VStack(alignment: .leading, spacing: 8) {
                    typeSegments
                    HStack(spacing: 8) {
                        moreTypes
                        modePicker
                    }
                }
            }
            if model.mode == .compare { compareServers }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            switch model.mode {
            case .lookup: lookupResult
            case .compare: compareResult
            case .propagation: propagationResult
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

    private var runLabel: String {
        switch model.mode {
        case .lookup: return "Résoudre"
        case .compare: return "Comparer"
        case .propagation: return "Vérifier"
        }
    }

    private var runningLabel: String { model.mode == .lookup ? "Résolution…" : "Interrogation…" }

    private func run() { model.run(store: store, compareOptions: compareOptions) }

    // MARK: Type et vue

    private var typeSegments: some View {
        Picker("Type d’enregistrement", selection: Binding<DNSRecordType?>(
            get: { Self.mainTypes.contains(model.type) ? model.type : nil },
            set: { if let type = $0 { choose(type) } })) {
            ForEach(Self.mainTypes) { type in
                Text(type.rawValue).tag(Optional(type))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var moreTypes: some View {
        Menu {
            ForEach(Self.moreTypes) { type in
                Button(type.rawValue) { choose(type) }
            }
        } label: {
            Text(Self.moreTypes.contains(model.type) ? model.type.rawValue : "Autres")
                .font(.system(size: 12, weight: Self.moreTypes.contains(model.type) ? .semibold : .regular))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("SOA, SRV, CAA, DNSKEY, DS")
    }

    private func choose(_ type: DNSRecordType) {
        model.type = type
        if !model.query.isEmpty && model.mode == .lookup { run() }
    }

    private var modePicker: some View {
        Picker("Vue", selection: $model.mode) {
            ForEach(DNSToolMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Serveurs

    private var serverOptions: [(String, IPv4Address)] {
        var list: [(String, IPv4Address)] = []
        if let gateway = state.activeInterface?.gateway { list.append(("\(gateway) (passerelle)", gateway)) }
        for server in state.dnsServers where !list.contains(where: { $0.1 == server }) {
            list.append(("\(server) (DNS du réseau)", server))
        }
        for preset in DNSPublicResolver.presets where !list.contains(where: { $0.1 == preset.address }) {
            list.append(("\(preset.address) (\(preset.name))", preset.address))
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
        .menuStyle(.button)
        .controlSize(.large)
        .frame(width: 230)
    }

    /// Serveurs proposés pour la comparaison : système, passerelle, DNS du réseau, résolveurs publics.
    private var compareOptions: [DNSServerOption] {
        var list = [DNSServerOption(name: "Résolveur du système", address: nil)]
        if let gateway = state.activeInterface?.gateway { list.append(DNSServerOption(name: "Passerelle", address: gateway)) }
        for server in state.dnsServers where !list.contains(where: { $0.address == server }) {
            list.append(DNSServerOption(name: "DNS du réseau", address: server))
        }
        for preset in DNSPublicResolver.presets where !list.contains(where: { $0.address == preset.address }) {
            list.append(DNSServerOption(name: preset.name, address: preset.address, region: preset.region))
        }
        return list
    }

    private var compareServers: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Serveurs à comparer")
            ToolFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(compareOptions) { option in
                    ToolChoiceChip(label: option.label, isSelected: model.compareSelection.contains(option.id), mono: false) {
                        if model.compareSelection.contains(option.id) {
                            model.compareSelection.remove(option.id)
                        } else {
                            model.compareSelection.insert(option.id)
                        }
                    }
                }
                ToolTextField(placeholder: "Autre (IPv4)", text: $model.compareCustom,
                              invalid: !model.compareCustom.isEmpty && IPv4Address(model.compareCustom) == nil, height: 24)
                    .frame(width: 130)
            }
        }
    }

    // MARK: Résultats

    @ViewBuilder private var lookupResult: some View {
        if let result = model.result {
            HStack(alignment: .center, spacing: 8) {
                Text(result.summary).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
            }
            DNSRecordTable(rows: DNSRecordRow.rows(of: result), table: table)
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

    @ViewBuilder private var compareResult: some View {
        if let comparison = model.comparison {
            ToolNotice(tone: comparison.isConsistent ? .success : .warning,
                       title: comparison.isConsistent ? "Réponses identiques" : "Les serveurs ne donnent pas la même réponse",
                       message: "\(comparison.query) \(comparison.type.rawValue) · \(comparison.summary)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(comparison.answers) { answer in
                    DNSServerCard(answer: answer, comparison: comparison)
                }
            }
        } else if model.error == nil {
            Text("La même question est posée en même temps à chaque serveur coché\u{00A0}; les réponses s’affichent côte à côte et les écarts sont signalés (un TTL différent n’est pas un écart).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var propagationResult: some View {
        if let propagation = model.propagation {
            ToolNotice(tone: propagation.isConsistent ? .success : .warning,
                       title: propagation.isConsistent ? "Propagation terminée" : "Propagation incomplète",
                       message: "\(propagation.query) \(propagation.type.rawValue) · \(propagation.summary)")
            HStack {
                ToolFieldLabel("Résolveurs publics")
                Spacer()
                ToolColumnsMenu(model: propagationTable)
            }
            DNSPropagationTable(rows: DNSPropagationRow.rows(of: propagation), table: propagationTable)
            Text("Un résolveur qui garde l’ancienne réponse la rend jusqu’à l’expiration de son cache (colonne TTL).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        } else if model.error == nil {
            Text("Après un changement d’enregistrement, la même question est posée à \(DNSPublicResolver.propagation.count) résolveurs publics (Cloudflare, Google, Quad9, OpenDNS, CIRA…) pour voir lesquels donnent déjà la nouvelle réponse.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

// MARK: - Carte d'un serveur (comparaison)

private struct DNSServerCard: View {
    let answer: DNSServerAnswer
    let comparison: DNSComparison

    var body: some View {
        let agreement = comparison.agreement(of: answer)
        let extra = Set(comparison.differences(of: answer).extra)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(answer.name).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                    Text(answer.address?.description ?? "macOS").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Chip(text: agreement.label, tone: tone(agreement))
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if let result = answer.result {
                if result.answerCount == 0 {
                    Text("Aucun enregistrement (\(result.rcode))").font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(result.records.enumerated()), id: \.offset) { _, record in
                            let differs = extra.contains("\(record.typeLabel) \(record.value.lowercased())")
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(record.value)
                                    .font(Theme.mono(12, weight: differs ? .semibold : .medium))
                                    .foregroundStyle(differs ? Theme.warning : Theme.text)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(record.value)
                                Spacer(minLength: 4)
                                Text("TTL \(record.ttl)").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                Text("\(result.rcode) · \(ToolFormat.milliseconds(result.durationMs))")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text(answer.error ?? "Aucune réponse").font(Theme.small).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .strokeBorder(agreement == .agrees ? Theme.border : tone(agreement).foreground.opacity(0.6)))
    }

    private func tone(_ agreement: DNSAgreement) -> Tone {
        switch agreement {
        case .agrees: return .success
        case .differs: return .warning
        case .failed: return .critical
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
    /// Explication en clair (SOA, SRV, CAA, DNSKEY, DS…).
    let note: String

    var sortName: String { record.name.lowercased() }
    var sortType: String { record.typeLabel }
    var sortTTL: UInt32 { record.ttl }
    var sortValue: String { record.value.lowercased() }

    static func rows(of result: DNSLookupResult) -> [DNSRecordRow] {
        let section = result.answerCount == 0 ? "autorité" : "réponse"
        return result.records.enumerated().map { index, record in
            DNSRecordRow(id: index, record: record, section: section, server: result.serverLabel,
                         note: DNSRecordNote.describe(record) ?? "")
        }
    }
}

/// Enregistrements DNS (tableau standard « outils.dns », note 8) : nom, type, TTL, valeur,
/// explication ; facultatives : rang dans la réponse, section, serveur interrogé.
struct DNSRecordTable: View {
    let rows: [DNSRecordRow]
    @ObservedObject var table: StandardTableModel<DNSRecordRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "ttl", title: "TTL"),
        StandardColumn(id: "valeur", title: "Valeur"),
        StandardColumn(id: "explication", title: "Explication"),
        StandardColumn(id: "rang", title: "Rang dans la réponse", isDefaultVisible: false),
        StandardColumn(id: "section", title: "Section", isDefaultVisible: false),
        StandardColumn(id: "serveur", title: "Serveur interrogé", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<DNSRecordRow>] = [
        "nom": KeyPathComparator(\DNSRecordRow.sortName),
        "type": KeyPathComparator(\DNSRecordRow.sortType),
        "ttl": KeyPathComparator(\DNSRecordRow.sortTTL),
        "valeur": KeyPathComparator(\DNSRecordRow.sortValue),
        "explication": KeyPathComparator(\DNSRecordRow.note),
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
                .width(min: 90, ideal: 110)
                .customizationID("nom")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    Chip(text: row.record.typeLabel, tone: .accent, mono: true)
                }
                .width(min: 50, ideal: 58)
                .customizationID("type")

                TableColumn("TTL", sortUsing: table.sort("ttl")) { row in
                    ToolTableText(String(row.record.ttl), alignment: .trailing)
                }
                .width(min: 40, ideal: 46)
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
                .width(min: 100, ideal: 160)
                .customizationID("valeur")

                TableColumn("EXPLICATION", sortUsing: table.sort("explication")) { row in
                    ToolTableText(row.note, mono: false, color: Theme.textSecondary).help(row.note)
                }
                .width(min: 90, ideal: 150)
                .customizationID("explication")

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

// MARK: - Tableau de la propagation

struct DNSPropagationRow: Identifiable {
    let id: Int
    let name: String
    let address: String
    let region: String
    let agreement: DNSAgreement
    let answer: String
    let ttl: UInt32?
    let durationMs: Double?

    var sortAgreement: Int {
        switch agreement {
        case .differs: return 0
        case .failed: return 1
        case .agrees: return 2
        }
    }
    var sortTTL: UInt32 { ttl ?? 0 }
    var sortDuration: Double { durationMs ?? .greatestFiniteMagnitude }

    static func rows(of comparison: DNSComparison) -> [DNSPropagationRow] {
        comparison.answers.enumerated().map { index, answer in
            let text: String
            if let result = answer.result {
                text = result.answerCount == 0 ? "aucun enregistrement (\(result.rcode))"
                                               : result.records.map(\.value).joined(separator: ", ")
            } else {
                text = answer.error ?? "aucune réponse"
            }
            return DNSPropagationRow(id: index, name: answer.name, address: answer.address?.description ?? "système",
                                     region: answer.region ?? "", agreement: comparison.agreement(of: answer), answer: text,
                                     ttl: answer.minTTL, durationMs: answer.result?.durationMs)
        }
    }
}

/// Propagation (tableau standard « outils.dns.propagation ») : résolveur, région, état, réponse,
/// TTL, temps ; facultative : adresse du résolveur.
struct DNSPropagationTable: View {
    let rows: [DNSPropagationRow]
    @ObservedObject var table: StandardTableModel<DNSPropagationRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "resolveur", title: "Résolveur", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse", isDefaultVisible: false),
        StandardColumn(id: "region", title: "Région"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "reponse", title: "Réponse"),
        StandardColumn(id: "ttl", title: "TTL"),
        StandardColumn(id: "temps", title: "Temps"),
    ]

    static let sortKeys: [String: KeyPathComparator<DNSPropagationRow>] = [
        "resolveur": KeyPathComparator(\DNSPropagationRow.name),
        "adresse": KeyPathComparator(\DNSPropagationRow.address),
        "region": KeyPathComparator(\DNSPropagationRow.region),
        "etat": KeyPathComparator(\DNSPropagationRow.sortAgreement),
        "reponse": KeyPathComparator(\DNSPropagationRow.answer),
        "ttl": KeyPathComparator(\DNSPropagationRow.sortTTL),
        "temps": KeyPathComparator(\DNSPropagationRow.sortDuration),
        "ordre": KeyPathComparator(\DNSPropagationRow.id),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<DNSPropagationRow> {
        StandardTableModel(id: "outils.dns.propagation", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucun résolveur.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("RÉSOLVEUR", sortUsing: table.sort("resolveur")) { row in
                    ToolTableText(row.name, mono: false, weight: .medium)
                }
                .width(min: 100, ideal: 130)
                .customizationID("resolveur")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.address, color: Theme.textSecondary)
                }
                .width(min: 90, ideal: 110)
                .customizationID("adresse")
                .defaultVisibility(.hidden)

                TableColumn("RÉGION", sortUsing: table.sort("region")) { row in
                    ToolTableText(row.region, mono: false, color: Theme.textSecondary)
                }
                .width(min: 60, ideal: 96)
                .customizationID("region")

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    Chip(text: row.agreement.label, tone: row.agreement == .agrees ? .success : (row.agreement == .differs ? .warning : .critical))
                }
                .width(min: 80, ideal: 86)
                .customizationID("etat")

                TableColumn("RÉPONSE", sortUsing: table.sort("reponse")) { row in
                    ToolTableText(row.answer, weight: row.agreement == .differs ? .semibold : .regular,
                                  color: row.agreement == .differs ? Theme.warning : (row.agreement == .failed ? Theme.textSecondary : Theme.text))
                        .help(row.answer)
                }
                .width(min: 100, ideal: 136)
                .customizationID("reponse")

                TableColumn("TTL", sortUsing: table.sort("ttl")) { row in
                    ToolTableText(row.ttl.map(String.init) ?? "—", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 40, ideal: 44)
                .customizationID("ttl")

                TableColumn("TEMPS", sortUsing: table.sort("temps")) { row in
                    ToolTableText(row.durationMs.map(ToolFormat.milliseconds) ?? "—", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 48, ideal: 54)
                .customizationID("temps")
            }
        }
    }
}
