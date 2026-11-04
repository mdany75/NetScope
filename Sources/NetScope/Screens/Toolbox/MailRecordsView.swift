import NetScopeCore
import SwiftUI

/// Résultats des six analyses d'un domaine (SPF, DMARC, DKIM, BIMI, MTA-STS, TLS-RPT).
struct MailRecordsResult {
    var domain: String
    var spf: SPFReport
    var dmarc: DMARCReport
    var dkim: DKIMReport
    var bimi: BIMIReport
    var mtaSTS: MTASTSReport
    var tlsRPT: TLSRPTReport

    func status(_ kind: MailRecordKind) -> MailStatus {
        switch kind {
        case .spf: return spf.status
        case .dmarc: return dmarc.status
        case .dkim: return dkim.status
        case .bimi: return bimi.status
        case .mtasts: return mtaSTS.status
        case .tlsrpt: return tlsRPT.status
        }
    }

    func findings(_ kind: MailRecordKind) -> [MailFinding] {
        switch kind {
        case .spf: return spf.findings
        case .dmarc: return dmarc.findings
        case .dkim: return dkim.findings
        case .bimi: return bimi.findings
        case .mtasts: return mtaSTS.findings
        case .tlsrpt: return tlsRPT.findings
        }
    }

    func summary(_ kind: MailRecordKind) -> String {
        switch kind {
        case .spf: return spf.summary
        case .dmarc: return dmarc.summary
        case .dkim: return dkim.summary
        case .bimi: return bimi.summary
        case .mtasts: return mtaSTS.summary
        case .tlsrpt: return tlsRPT.summary
        }
    }
}

@MainActor
final class ToolMailRecordsModel: ObservableObject {
    @Published var domain = ""
    @Published var kind: MailRecordKind = .spf
    /// Sélecteur DKIM saisi (essayé avant les sélecteurs courants).
    @Published var selector = ""
    /// Sélecteur dont les étiquettes sont affichées.
    @Published var shownSelector: String?
    @Published private(set) var isRunning = false
    @Published private(set) var result: MailRecordsResult?
    @Published var error: String?
    private var generation = 0

    var command: String {
        let name = MailTools.domain(from: domain) ?? "<domaine>"
        let selector = self.selector.trimmingCharacters(in: .whitespaces).isEmpty ? "selector1" : self.selector
        if kind == .mtasts { return "curl https://mta-sts.\(name)/.well-known/mta-sts.txt" }
        return "dig +short TXT \(kind.recordName(domain: name, selector: selector))"
    }

    func run(store: ToolStore?) {
        guard let name = MailTools.domain(from: domain) else {
            error = "Saisir un domaine (exemple.ca) ou une adresse courriel."
            return
        }
        domain = name
        error = nil
        isRunning = true
        generation += 1
        let run = generation
        let selectors = selector.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let client = MailTools.client
        store?.record(command: command)
        Task {
            async let spf = SPFAnalyzer.analyze(name, client: client)
            async let dmarc = DMARCAnalyzer.analyze(name, client: client)
            async let dkim = DKIMAnalyzer.scan(name, selectors: selectors + DKIMAnalyzer.commonSelectors, client: client)
            async let tls = MailPolicyAnalyzer.tlsRPT(name, client: client)
            let mxHosts = await client.query(name, .mx).values.compactMap(MailDNSText.parseMX).map(\.host)
            async let mta = MailPolicyAnalyzer.mtaSTS(name, mxHosts: mxHosts, client: client)
            let dmarcReport = await dmarc
            let bimi = await MailPolicyAnalyzer.bimi(name, dmarc: dmarcReport.record, client: client)
            let result = MailRecordsResult(domain: name, spf: await spf, dmarc: dmarcReport, dkim: await dkim, bimi: bimi,
                                           mtaSTS: await mta, tlsRPT: await tls)
            guard run == self.generation else { return }
            self.result = result
            self.shownSelector = result.dkim.found.first?.selector
            self.isRunning = false
            let worst = MailStatus.worst(MailRecordKind.allCases.map(result.status))
            store?.record(ToolRecent(tool: .mailRecords, target: name,
                                     summary: "SPF \(result.spf.summary) · DMARC \(result.dmarc.summary)",
                                     status: worst == .error ? .failure : (worst == .warning ? .warning : .ok)))
        }
    }

    /// Démonstration : exemple.ca ; NETSCOPE_COURRIEL_ONGLET=dkim (ou dmarc…) ouvre cet onglet.
    func startDemo() {
        domain = MailDemo.domain
        if let raw = ProcessInfo.processInfo.environment["NETSCOPE_COURRIEL_ONGLET"], let kind = MailRecordKind(rawValue: raw) {
            self.kind = kind
        }
        run(store: nil)
    }
}

/// SPF, DMARC, DKIM, BIMI, MTA-STS et TLS-RPT : enregistrement lu, expliqué terme à terme, erreurs.
struct MailRecordsView: View {
    @ObservedObject var model: ToolMailRecordsModel
    @ObservedObject var store: ToolStore
    @StateObject private var tagTable = MailTagTable.makeModel()
    @StateObject private var spfTable = SPFTreeTable.makeModel()
    @StateObject private var dkimTable = DKIMSelectorTable.makeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Domaine") {
                    ToolTextField(placeholder: "exemple.ca ou nom@exemple.ca", text: $model.domain) { model.run(store: store) }
                        .frame(minWidth: 180)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ToolLabeledField(label: "Sélecteur DKIM (facultatif)") {
                        ToolTextField(placeholder: "ex. s2024", text: $model.selector) { model.run(store: store) }
                            .frame(width: 150)
                    }
                    Button(model.isRunning ? "Analyse…" : "Analyser") { model.run(store: store) }
                        .buttonStyle(.primary)
                        .disabled(model.isRunning)
                        .fixedSize()
                }
            }
            // Segments quand la place suffit, sinon menu déroulant (petite fenêtre).
            ViewThatFits(in: .horizontal) {
                kindPicker.pickerStyle(.segmented).fixedSize()
                kindPicker.pickerStyle(.menu).fixedSize()
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.isRunning {
                MailProgressLine(text: "Lecture des six enregistrements de \(model.domain)…")
            } else if let result = model.result {
                detail(result)
            } else if model.error == nil {
                Text("Lit les enregistrements d’authentification du domaine, explique chaque terme et signale les erreurs\u{00A0}: plus de 10 recherches DNS SPF, «\u{00A0}+all\u{00A0}», politique DMARC «\u{00A0}none\u{00A0}», clé DKIM trop courte ou révoquée, syntaxe. Les sélecteurs DKIM courants sont essayés.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kindPicker: some View {
        Picker("Enregistrement", selection: $model.kind) {
            ForEach(MailRecordKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder private func detail(_ result: MailRecordsResult) -> some View {
        let kind = model.kind
        HStack(alignment: .center, spacing: 8) {
            MailStatusChip(status: result.status(kind))
            Text(kind == .dkim ? "<sélecteur>._domainkey.\(result.domain)" : kind.recordName(domain: result.domain))
                .font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Text(result.summary(kind)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        switch kind {
        case .spf: spfDetail(result.spf)
        case .dmarc: tagDetail(.dmarc, text: result.dmarc.record?.text, location: result.dmarc.location)
        case .dkim: dkimDetail(result.dkim)
        case .bimi: tagDetail(.bimi, text: result.bimi.record?.text, location: nil)
        case .mtasts: mtaDetail(result.mtaSTS)
        case .tlsrpt: tagDetail(.tlsrpt, text: result.tlsRPT.record?.text, location: nil)
        }
        let findings = result.findings(kind).bySeverity
        if !findings.isEmpty {
            ToolFieldLabel("Constats")
            MailFindingList(findings: findings)
        }
    }

    @ViewBuilder private func spfDetail(_ report: SPFReport) -> some View {
        if let record = report.record {
            MailRawRecord(text: record.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 8) { spfTiles(report) }
            HStack {
                ToolFieldLabel("Arbre des include et redirect")
                Spacer()
                ToolColumnsMenu(model: spfTable)
            }
            SPFTreeTable(rows: SPFTreeRow.rows(report), table: spfTable)
            HStack {
                ToolFieldLabel("Termes de l’enregistrement")
                Spacer()
                ToolColumnsMenu(model: tagTable)
            }
            MailTagTable(rows: MailExplain.spf(record), table: tagTable)
        }
    }

    @ViewBuilder private func spfTiles(_ report: SPFReport) -> some View {
        let over = report.totalLookups > SPFAnalyzer.lookupLimit
        ToolStatTile(label: "Recherches DNS", value: "\(report.totalLookups)\u{00A0}/\u{00A0}\(SPFAnalyzer.lookupLimit)",
                     detail: over ? "permerror" : "limite respectée",
                     valueColor: over ? Theme.critical : (report.totalLookups >= SPFAnalyzer.lookupLimit - 1 ? Theme.warning : Theme.success))
        ToolStatTile(label: "Recherches vides", value: "\(report.voidLookups)\u{00A0}/\u{00A0}\(SPFAnalyzer.voidLimit)",
                     detail: "noms sans réponse", valueColor: report.voidLookups > SPFAnalyzer.voidLimit ? Theme.warning : Theme.text)
        ToolStatTile(label: "Règle finale", value: report.allQualifier.map { "\($0)all" } ?? "aucune",
                     detail: report.allQualifier == "-" ? "refus" : (report.allQualifier == "~" ? "échec léger" : "à durcir"),
                     valueColor: report.allQualifier == "+" ? Theme.critical : Theme.text)
        ToolStatTile(label: "Enregistrements suivis", value: "\(report.nodes.count)", detail: "racine et include")
    }

    @ViewBuilder private func tagDetail(_ kind: MailRecordKind, text: String?, location: String?) -> some View {
        if let text {
            if let location, location != kind.recordName(domain: model.result?.domain ?? "") {
                Text("Trouvé à \(location)").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            MailRawRecord(text: text)
            HStack {
                ToolFieldLabel("Étiquettes")
                Spacer()
                ToolColumnsMenu(model: tagTable)
            }
            MailTagTable(rows: MailExplain.tags(kind, text: text), table: tagTable)
        }
    }

    @ViewBuilder private func dkimDetail(_ report: DKIMReport) -> some View {
        HStack {
            ToolFieldLabel("Sélecteurs trouvés (\(report.found.count) sur \(report.tried) essayés)")
            Spacer()
            ToolColumnsMenu(model: dkimTable)
        }
        DKIMSelectorTable(rows: DKIMSelectorRow.rows(report), table: dkimTable)
        if !report.found.isEmpty {
            Picker("Sélecteur affiché", selection: Binding(get: { model.shownSelector ?? report.found[0].selector },
                                                           set: { model.shownSelector = $0 })) {
                ForEach(report.found) { found in Text(found.selector).tag(found.selector) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let shown = report.found.first(where: { $0.selector == (model.shownSelector ?? report.found[0].selector) }),
               let key = shown.key {
                Text(shown.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                MailRawRecord(text: key.text)
                MailTagTable(rows: MailExplain.tags(.dkim, text: key.text), table: tagTable)
            }
        }
    }

    @ViewBuilder private func mtaDetail(_ report: MTASTSReport) -> some View {
        if let record = report.record {
            MailRawRecord(text: record)
            HStack {
                ToolFieldLabel("Étiquettes du TXT")
                Spacer()
                ToolColumnsMenu(model: tagTable)
            }
            MailTagTable(rows: MailExplain.tags(.mtasts, text: record), table: tagTable)
            if let url = report.policyURL {
                ToolFieldLabel("Fichier de politique")
                Text(url.absoluteString).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            if let text = report.policyText {
                MailTagTable(rows: MailExplain.mtaSTSPolicy(text), table: tagTable)
            }
        }
    }
}

// MARK: - Tableau des étiquettes

/// Étiquettes d'un enregistrement (tableau standard « outils.courriel.etiquettes ») :
/// état, étiquette, valeur, signification.
struct MailTagTable: View {
    let rows: [MailTagExplanation]
    @ObservedObject var table: StandardTableModel<MailTagExplanation>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "etiquette", title: "Étiquette", isRequired: true),
        StandardColumn(id: "valeur", title: "Valeur"),
        StandardColumn(id: "signification", title: "Signification"),
    ]

    static let sortKeys: [String: KeyPathComparator<MailTagExplanation>] = [
        "rang": KeyPathComparator(\MailTagExplanation.id),
        "etat": KeyPathComparator(\MailTagExplanation.status),
        "etiquette": KeyPathComparator(\MailTagExplanation.tag),
        "valeur": KeyPathComparator(\MailTagExplanation.value),
        "signification": KeyPathComparator(\MailTagExplanation.meaning),
    ]

    /// Tri par défaut : l'ordre de l'enregistrement.
    @MainActor
    static func makeModel() -> StandardTableModel<MailTagExplanation> {
        StandardTableModel(id: "outils.courriel.etiquettes", columns: columns, sortKeys: sortKeys, defaultSort: "rang")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 20, emptyText: "Aucune étiquette.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    Image(systemName: row.status.symbol).foregroundStyle(row.status.tone.foreground).help(row.status.label)
                }
                .width(min: 36, ideal: 44, max: 60)
                .customizationID("etat")

                TableColumn("ÉTIQUETTE", sortUsing: table.sort("etiquette")) { row in
                    ToolTableText(row.tag, weight: .semibold)
                }
                .width(min: 60, ideal: 80)
                .customizationID("etiquette")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("VALEUR", sortUsing: table.sort("valeur")) { row in
                    Text(row.value)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 80, ideal: 120)
                .customizationID("valeur")

                TableColumn("SIGNIFICATION", sortUsing: table.sort("signification")) { row in
                    ToolTableText(row.meaning, mono: false, color: Theme.textSecondary).help(row.meaning)
                }
                .width(min: 120, ideal: 200)
                .customizationID("signification")
            }
        }
    }
}

// MARK: - Arbre SPF

struct SPFTreeRow: Identifiable {
    let id: Int
    let node: SPFNode

    var sortDomain: String { node.domain }
    var sortVia: String { node.via }
    var sortOwn: Int { node.lookups }
    var sortTotal: Int { node.subtreeLookups }
    var sortRecord: String { node.problem ?? node.record ?? "" }

    static func rows(_ report: SPFReport) -> [SPFTreeRow] {
        report.nodes.map { SPFTreeRow(id: $0.id, node: $0) }
    }
}

/// Arbre SPF (tableau standard « outils.courriel.spf ») : domaine (en retrait), lien, recherches
/// propres et cumulées, enregistrement ou problème.
struct SPFTreeTable: View {
    let rows: [SPFTreeRow]
    @ObservedObject var table: StandardTableModel<SPFTreeRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "domaine", title: "Domaine", isRequired: true),
        StandardColumn(id: "via", title: "Lien"),
        StandardColumn(id: "propres", title: "Recherches"),
        StandardColumn(id: "cumul", title: "Cumul"),
        StandardColumn(id: "enregistrement", title: "Enregistrement"),
    ]

    static let sortKeys: [String: KeyPathComparator<SPFTreeRow>] = [
        "ordre": KeyPathComparator(\SPFTreeRow.id),
        "domaine": KeyPathComparator(\SPFTreeRow.sortDomain),
        "via": KeyPathComparator(\SPFTreeRow.sortVia),
        "propres": KeyPathComparator(\SPFTreeRow.sortOwn),
        "cumul": KeyPathComparator(\SPFTreeRow.sortTotal),
        "enregistrement": KeyPathComparator(\SPFTreeRow.sortRecord),
    ]

    /// Tri par défaut : l'ordre de l'arbre (parcours en profondeur).
    @MainActor
    static func makeModel() -> StandardTableModel<SPFTreeRow> {
        StandardTableModel(id: "outils.courriel.spf", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 20, emptyText: "Aucun enregistrement.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("DOMAINE", sortUsing: table.sort("domaine")) { row in
                    HStack(spacing: 4) {
                        if row.node.depth > 0 {
                            Text(String(repeating: "   ", count: row.node.depth - 1) + "└")
                                .font(Theme.mono(12)).foregroundStyle(Theme.textTertiary)
                        }
                        ToolTableText(row.node.domain, weight: row.node.depth == 0 ? .semibold : .regular).help(row.node.domain)
                    }
                }
                .width(min: 130, ideal: 160)
                .customizationID("domaine")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("LIEN", sortUsing: table.sort("via")) { row in
                    ToolTableText(row.node.via, mono: false, color: Theme.textSecondary)
                }
                .width(min: 50, ideal: 56)
                .customizationID("via")

                TableColumn("RECHERCHES", sortUsing: table.sort("propres")) { row in
                    ToolTableText("\(row.node.lookups)", alignment: .trailing)
                }
                .width(min: 80, ideal: 84)
                .customizationID("propres")

                TableColumn("CUMUL", sortUsing: table.sort("cumul")) { row in
                    ToolTableText("\(row.node.subtreeLookups)", weight: .semibold,
                                  color: row.node.depth == 0 && row.node.subtreeLookups > SPFAnalyzer.lookupLimit ? Theme.critical : Theme.text,
                                  alignment: .trailing)
                }
                .width(min: 46, ideal: 50)
                .customizationID("cumul")

                TableColumn("ENREGISTREMENT", sortUsing: table.sort("enregistrement")) { row in
                    if let problem = row.node.problem {
                        MailStatusChip(status: problem == "boucle" || problem == "aucun SPF" ? .error : .warning, text: problem)
                    } else {
                        ToolTableText(row.node.record ?? "", color: Theme.textSecondary).help(row.node.record ?? "")
                    }
                }
                .width(min: 80, ideal: 90)
                .customizationID("enregistrement")
            }
        }
    }
}

// MARK: - Sélecteurs DKIM

struct DKIMSelectorRow: Identifiable {
    let id: Int
    let result: DKIMSelectorResult

    var sortSelector: String { result.selector }
    var sortBits: Int { result.key?.bits ?? 0 }
    var sortStatus: Int { [MailStatus.error, .warning, .info, .ok].firstIndex(of: result.status) ?? 4 }
    var keyType: String { result.key.map { $0.keyType == "ed25519" ? "Ed25519" : "RSA" } ?? "—" }

    static func rows(_ report: DKIMReport) -> [DKIMSelectorRow] {
        report.found.enumerated().map { DKIMSelectorRow(id: $0.offset, result: $0.element) }
    }
}

/// Sélecteurs DKIM trouvés (tableau standard « outils.courriel.dkim ») : sélecteur, type,
/// taille, état ; facultative : nom DNS.
struct DKIMSelectorTable: View {
    let rows: [DKIMSelectorRow]
    @ObservedObject var table: StandardTableModel<DKIMSelectorRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "selecteur", title: "Sélecteur", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "nom", title: "Nom DNS", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<DKIMSelectorRow>] = [
        "selecteur": KeyPathComparator(\DKIMSelectorRow.sortSelector),
        "type": KeyPathComparator(\DKIMSelectorRow.keyType),
        "taille": KeyPathComparator(\DKIMSelectorRow.sortBits),
        "etat": KeyPathComparator(\DKIMSelectorRow.sortStatus),
        "nom": KeyPathComparator(\DKIMSelectorRow.sortSelector),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<DKIMSelectorRow> {
        StandardTableModel(id: "outils.courriel.dkim", columns: columns, sortKeys: sortKeys, defaultSort: "selecteur")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucune clé trouvée avec les sélecteurs courants.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("SÉLECTEUR", sortUsing: table.sort("selecteur")) { row in
                    ToolTableText(row.result.selector, weight: .semibold)
                }
                .width(min: 80, ideal: 120)
                .customizationID("selecteur")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                    ToolTableText(row.keyType, mono: false)
                }
                .width(min: 50, ideal: 70)
                .customizationID("type")

                TableColumn("TAILLE", sortUsing: table.sort("taille")) { row in
                    ToolTableText(row.result.key?.revoked == true ? "révoquée" : (row.result.key?.bits.map { "\($0) bits" } ?? "—"),
                                  alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
                .customizationID("taille")

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    MailStatusChip(status: row.result.status, text: row.result.summary)
                }
                .width(min: 120, ideal: 220)
                .customizationID("etat")

                TableColumn("NOM DNS", sortUsing: table.sort("nom")) { row in
                    ToolTableText(row.result.name, color: Theme.textSecondary).help(row.result.name)
                }
                .width(min: 140, ideal: 260)
                .customizationID("nom")
                .defaultVisibility(.hidden)
            }
        }
    }
}
