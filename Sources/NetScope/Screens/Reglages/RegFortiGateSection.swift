import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Réglages › Switchs › Contrôleurs FortiGate (notes 24 et 25) : une FortiGate par site, chacune
/// avec son jeton (Trousseau, un compte par contrôleur), son empreinte de certificat et les plages
/// qu'elle couvre. En fin de scan, seules les FortiGate qui couvrent les plages scannées (sinon
/// l'adresse du Mac) sont lues. NetScope ne lit que les FortiGate, jamais les FortiSwitch.
struct RegFortiGatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared
    @StateObject private var table = RegFortiControllerTable.makeModel()
    @StateObject private var switchTable = RegFortiSwitchTable.makeModel()
    @State private var selectedID: UUID?
    @State private var editing: RegFortiControllerDraft?
    @State private var removing: FortiGateController?
    @State private var importMessage: (text: String, details: [String], tone: Tone)?
    @State private var showHelp = false
    @State private var loaded = false

    var body: some View {
        RegPanel(title: "Contrôleurs FortiGate",
                 subtitle: "FortiSwitch gérés par FortiLink\u{00A0}: NetScope lit la FortiGate de chaque site par son API REST (HTTPS, lecture seule) et n’interroge jamais les switchs, dont les adresses FortiLink (10.255.1.0/24 par défaut) ne sont pas joignables depuis ce Mac. À la fin d’un scan, seules les FortiGate qui couvrent les plages scannées (sinon l’adresse de ce Mac) sont lues, et passent avant SNMP pour le switch, le port et le VLAN de chaque appareil.") {
            summaryChip
        } content: {
            if let draft = RegFortiControllerDraft.snapshotDraft {
                // Captures : la feuille d'édition, dessinée en haut de la page (une feuille n'est pas capturée).
                RegFortiControllerEditor(draft: draft, inline: true, dismiss: {})
                    .frame(maxWidth: 640, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .padding(.bottom, 14)
            }
            RegToggleRow(title: "Lire les FortiGate à chaque scan",
                         detail: "À la fin de chaque scan et avec «\u{00A0}Interroger les switchs\u{00A0}», NetScope relit, quatre à la fois au plus, les FortiGate choisies par plage\u{00A0}: FortiSwitch gérés, ports, PoE, appareils détectés, table ARP et baux DHCP (requêtes GET seulement\u{00A0}: rien n’est jamais modifié). La plage couverte la plus précise l’emporte\u{00A0}; aucune FortiGate\u{00A0}: SNMP seulement.",
                         isOn: $fortigate.isEnabled)
            toolbar
                .padding(.top, 10)
            if fortigate.controllers.isEmpty {
                emptyState
                    .padding(.top, 8)
            } else {
                RegFortiControllerTable(table: table, selection: $selectedID, edit: edit, remove: { removing = $0 })
                    .regTableFrame()
                    .padding(.top, 8)
            }
            notices
            if let id = selectedID, let c = fortigate.controller(id), let report = fortigate.runtime[id]?.report {
                selectedDetails(c, report)
                    .padding(.top, 14)
            }
            helpBox
                .padding(.top, 14)
        }
        .onAppear(perform: load)
        .task { await fortigate.loadTokens() }
        .sheet(item: $editing) { draft in
            RegFortiControllerEditor(draft: draft) { editing = nil }
        }
        .confirmationDialog("Supprimer cette FortiGate\u{00A0}?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Supprimer «\u{00A0}\(c.displayName)\u{00A0}»", role: .destructive) {
                fortigate.remove(c.id, state: state)
                if selectedID == c.id { selectedID = nil }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Son jeton sera aussi effacé du Trousseau. Ses FortiSwitch ne seront plus lus.")
        }
    }

    // MARK: En-tête

    @ViewBuilder private var summaryChip: some View {
        let count = fortigate.controllers.count
        if fortigate.isBusy || fortigate.isTestingAll {
            Chip(text: "Lecture…", tone: .accent)
        } else if count == 0 {
            Chip(text: "Aucune FortiGate", tone: .neutral)
        } else {
            let errors = fortigate.controllers.filter { $0.isEnabled && ($0.lastStatus?.kind == .error || $0.lastStatus?.kind == .certificate) }.count
            let missing = fortigate.controllers.filter { $0.isEnabled && !fortigate.hasToken($0.id) }.count
            HStack(spacing: 6) {
                Chip(text: "\(count) site\(count > 1 ? "s" : "")", tone: .neutral, mono: false)
                if errors > 0 { Chip(text: "\(errors) en erreur", tone: .critical) }
                if missing > 0 { Chip(text: "\(missing) sans jeton", tone: .warning) }
                if errors == 0 && missing == 0 { Chip(text: "Prêtes", tone: .success) }
            }
        }
    }

    // MARK: Barre d'actions

    private var selected: FortiGateController? { selectedID.flatMap(fortigate.controller) }

    private var toolbar: some View {
        // Petite fenêtre : les boutons passent à la ligne au lieu de déborder.
        FlowLayout(spacing: 8, lineSpacing: 8) {
            Button { edit(nil) } label: { Label("Ajouter", systemImage: "plus") }
                .buttonStyle(.primary)
            Button("Modifier…") { if let selected { edit(selected) } }
                .buttonStyle(.secondary)
                .regDisabled(selected == nil)
            Button("Supprimer…") { removing = selected }
                .buttonStyle(.secondary)
                .regDisabled(selected == nil)
            Button { importCSV() } label: { Label("Importer CSV…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .help("Fichier «\u{00A0}site;adresse;port;vdom;plages\u{00A0}» (en-tête facultatif, point-virgule ou virgule). Les jetons ne sont jamais dans le fichier\u{00A0}: saisissez-les ensuite, site par site.")
            Button { exportCSV() } label: { Label("Exporter CSV…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
                .regDisabled(fortigate.controllers.isEmpty)
                .help("Même forme que l’import, sans aucun jeton ni empreinte.")
            Button {
                fortigate.testAll()
            } label: {
                HStack(spacing: 6) {
                    if fortigate.isTestingAll { ProgressView().controlSize(.small) }
                    Text(fortigate.isTestingAll ? "Test…" : "Tester tout")
                }
            }
            .buttonStyle(.secondary)
            .regDisabled(fortigate.isTestingAll || fortigate.enabledControllers.isEmpty)
            .help("Teste chaque FortiGate activée, quatre à la fois\u{00A0}: le résultat s’affiche sur sa ligne. Les FortiSwitch de «\u{00A0}Switchs et ports\u{00A0}» ne changent pas.")
            StandardColumnsMenu(model: table)
        }
    }

    private var emptyState: some View {
        RegNotice("Aucune FortiGate. Cliquez sur «\u{00A0}Ajouter\u{00A0}» pour saisir celle d’un site, ou importez la liste de vos sites (CSV «\u{00A0}site;adresse;port;vdom;plages\u{00A0}»).", tone: .neutral)
    }

    // MARK: Avertissements

    @ViewBuilder private var notices: some View {
        let pending = fortigate.controllers.filter { fortigate.runtime[$0.id]?.pending != nil }
        let conflicts = fortigate.conflicts
        let unranged = fortigate.enabledControllers.filter { $0.coveredRanges.isEmpty }
        let invalid = fortigate.controllers.filter { !$0.invalidRanges.isEmpty }
        if importMessage != nil || !pending.isEmpty || !conflicts.isEmpty || !unranged.isEmpty || !invalid.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let importMessage {
                    let shown = Array(importMessage.details.prefix(6))
                    let more = importMessage.details.count - shown.count
                    let lines = [importMessage.text] + shown + (more > 0 ? ["… et \(more) autre\(more > 1 ? "s" : "") ligne\(more > 1 ? "s" : "")."] : [])
                    RegNotice(text: lines.joined(separator: "\n"), tone: importMessage.tone) {
                        Button("Fermer") { self.importMessage = nil }.buttonStyle(.secondary)
                    }
                }
                ForEach(pending) { c in pendingNotice(c) }
                ForEach(conflicts) { conflict in
                    RegNotice(conflict.message, tone: conflict.isAmbiguous ? .warning : .neutral)
                }
                if !unranged.isEmpty, fortigate.controllers.count > 1 || !fortigate.controllers.allSatisfy({ $0.coveredRanges.isEmpty }) {
                    RegNotice("Plages couvertes à renseigner pour " + unranged.map { "«\u{00A0}\($0.displayName)\u{00A0}»" }.joined(separator: ", ")
                              + "\u{00A0}: sans plage, une FortiGate n’est jamais choisie. «\u{00A0}Modifier…\u{00A0}» puis «\u{00A0}Tester\u{00A0}» propose les sous-réseaux de ses interfaces.",
                              tone: .warning)
                } else if !unranged.isEmpty {
                    RegNotice("Plages couvertes à renseigner\u{00A0}: tant qu’aucune FortiGate n’en a, celle-ci est lue à chaque scan, quelles que soient les plages. «\u{00A0}Modifier…\u{00A0}» puis «\u{00A0}Tester\u{00A0}» propose les sous-réseaux de ses interfaces.",
                              tone: .neutral)
                }
                ForEach(invalid) { c in
                    RegNotice("Plage illisible pour «\u{00A0}\(c.displayName)\u{00A0}», ignorée\u{00A0}: " + c.invalidRanges.joined(separator: ", "), tone: .critical)
                }
            }
            .padding(.top, 10)
        }
    }

    private func pendingNotice(_ c: FortiGateController) -> some View {
        let pending = fortigate.runtime[c.id]?.pending
        return VStack(alignment: .leading, spacing: 6) {
            Text(pending?.changed == true
                 ? "«\u{00A0}\(c.displayName)\u{00A0}»\u{00A0}: le certificat présenté ne correspond plus à l’empreinte acceptée. N’acceptez la nouvelle qu’après l’avoir vérifiée sur la FortiGate (certificat renouvelé)."
                 : "«\u{00A0}\(c.displayName)\u{00A0}»\u{00A0}: premier contact. Comparez l’empreinte SHA-256 avec celle du certificat de la FortiGate (System › Certificates) avant de l’accepter.")
                .font(Theme.small).foregroundStyle(pending?.changed == true ? Theme.critical : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let pending {
                RegFingerprintText(fingerprint: pending.fingerprint)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Refuser") { fortigate.rejectPendingCertificate(c.id) }.buttonStyle(.secondary)
                Button("Accepter cette empreinte") { fortigate.acceptPendingCertificate(c.id) }.buttonStyle(.primary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Tone.warning.background))
    }

    // MARK: FortiGate choisie dans le tableau

    private func selectedDetails(_ c: FortiGateController, _ report: FortiGateReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(c.displayName) · dernière lecture").font(Theme.bodySemibold)
                Text(SwitchText.ago(report.readAt)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                StandardColumnsMenu(model: switchTable, compact: true)
            }
            RegTileRow {
                RegTile("Modèle", report.system.model.isEmpty ? "—" : report.system.model)
                RegTile("Version de FortiOS", report.system.versionLabel, mono: true)
                RegTile("Nom d’hôte", report.controllerName, mono: true)
                RegTile("FortiSwitch gérés", "\(report.switches.count)")
                RegTile("Appareils détectés", "\(report.locatedDevices.count)")
                RegTile("Table ARP · baux DHCP", "\(report.arp.count) · \(report.dhcp.count)")
            }
            if !report.switches.isEmpty {
                RegFortiSwitchTable(table: switchTable, report: report, controllerID: c.id)
                    .regTableFrame()
            }
            RegFortiCallsSummary(calls: fortigate.runtime[c.id]?.calls ?? [])
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Aide

    private var helpBox: some View {
        DisclosureGroup(isExpanded: $showHelp) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(helpSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 18, alignment: .trailing)
                        Text(step).font(Theme.small).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Créer l’administrateur API REST en lecture seule sur chaque FortiGate (pas à pas)").font(Theme.bodySemibold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var helpSteps: [String] {
        let mac = state.activeInterface.map { "\($0.address.description)/32" } ?? "l’adresse IP de ce Mac suivie de /32"
        return [
            "Sur chaque FortiGate (ou dans FortiManager, si elles y sont gérées), ouvrez System › Admin Profiles › Create New. Nom\u{00A0}: «\u{00A0}netscope-lecture\u{00A0}». Mettez tout à «\u{00A0}None\u{00A0}», sauf «\u{00A0}WiFi & Switch Controller\u{00A0}» en «\u{00A0}Read\u{00A0}» (indispensable). Pour la table ARP, les baux DHCP, les noms d’appareils et les sous-réseaux des interfaces, ajoutez «\u{00A0}Network\u{00A0}», «\u{00A0}System\u{00A0}» et «\u{00A0}User & Device\u{00A0}» en «\u{00A0}Read\u{00A0}». Pour l’écran Trafic (FortiView, menaces, sessions), ajoutez aussi «\u{00A0}Log & Report\u{00A0}» et «\u{00A0}FortiView\u{00A0}» (s’il est proposé) en «\u{00A0}Read\u{00A0}». Aucun droit en écriture.",
            "System › Administrators › Create New › REST API Admin. Nom\u{00A0}: «\u{00A0}netscope\u{00A0}», profil\u{00A0}: «\u{00A0}netscope-lecture\u{00A0}». Laissez «\u{00A0}PKI Group\u{00A0}» et «\u{00A0}CORS\u{00A0}» décochés.",
            "Cochez «\u{00A0}Trusted Hosts\u{00A0}» et saisissez l’adresse par laquelle ce Mac arrive sur ce site\u{00A0}: \(mac) sur le réseau local, mais souvent le sous-réseau du VPN (FortiClient, IPsec entre sites) pour les autres sites. Une autre adresse donnera «\u{00A0}Accès refusé (HTTP 403)\u{00A0}».",
            "Cliquez OK\u{00A0}: la FortiGate affiche le jeton une seule fois. Dans NetScope, «\u{00A0}Ajouter\u{00A0}» (ou «\u{00A0}Modifier…\u{00A0}» après un import CSV), collez-le dans le champ du jeton\u{00A0}: il est gardé au Trousseau, un compte par FortiGate.",
            "Vérifiez que l’accès HTTPS d’administration est permis sur l’interface que joint ce Mac (Network › Interfaces › Administrative Access › HTTPS) et le port HTTPS (System › Settings, 443 par défaut, souvent 8443 ou 10443).",
            "Dans la feuille du site, saisissez l’adresse, le port et, seulement en mode multi-VDOM, le VDOM des FortiSwitch. «\u{00A0}Tester\u{00A0}»\u{00A0}: au premier contact, comparez l’empreinte du certificat avec celle de la FortiGate puis acceptez-la, et testez de nouveau. Les sous-réseaux de ses interfaces sont alors proposés comme plages couvertes (le réseau FortiLink n’est pas coché).",
            "Plusieurs sites\u{00A0}: importez la liste (CSV «\u{00A0}site;adresse;port;vdom;plages\u{00A0}», sans jeton), saisissez chaque jeton, puis «\u{00A0}Tester tout\u{00A0}». Deux FortiGate qui couvrent les mêmes adresses sont signalées\u{00A0}: la plage la plus précise l’emporte.",
            "Si une donnée manque (version de FortiOS différente), «\u{00A0}Copier les réponses brutes (diagnostic)\u{00A0}» dans la feuille du site\u{00A0}: le jeton en est retiré, le texte peut être transmis pour ajuster la lecture.",
        ]
    }

    // MARK: Actions

    private func edit(_ c: FortiGateController?) {
        if let c {
            editing = RegFortiControllerDraft(controller: c, isNew: false)
        } else {
            editing = RegFortiControllerDraft(controller: FortiGateController(site: "", host: ""), isNew: true)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Fichier «\u{00A0}site;adresse;port;vdom;plages\u{00A0}» (sans jeton)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            importMessage = ("Lecture impossible du fichier «\u{00A0}\(url.lastPathComponent)\u{00A0}».", [], .critical)
            return
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let result = fortigate.importCSV(text, state: state)
        // Le ton suit les lignes refusées seulement ; une simple remarque ne change rien.
        importMessage = (result.summary, result.errors + result.notes, result.errors.isEmpty ? .success : .warning)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "fortigate-sites.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fortigate.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            importMessage = ("Export enregistré\u{00A0}: \(url.lastPathComponent) (\(fortigate.controllers.count) FortiGate, sans jeton).", [], .success)
        } catch {
            importMessage = ("Export impossible\u{00A0}: \(error.localizedDescription)", [], .critical)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Captures : l'aide pas à pas est dépliée, et la première FortiGate est choisie.
        if RegEnvironment.isSnapshot {
            showHelp = ProcessInfo.processInfo.environment["NETSCOPE_FORTIGATE_AIDE"] == "1"
            selectedID = fortigate.controllers.first?.id
        }
    }
}

// MARK: - Tableau des contrôleurs

/// Ligne du tableau des FortiGate.
struct RegFortiControllerRow: Identifiable {
    let id: UUID
    /// Position dans la liste (1 = première) : elle départage deux plages de même précision.
    let order: Int
    let site: String
    let address: String
    let vdom: String
    let ranges: [String]
    let rangesSort: String
    let hasToken: Bool
    let tokenSort: Int
    let state: String
    let stateTone: Tone
    let stateHelp: String
    let stateRank: Int
    let lastTest: Date?
    let lastTestSort: Date
    let model: String
    let switches: Int
    let isEnabled: Bool
    let isUsed: Bool
    /// Raison du choix pour le scan (nil si elle n'est pas utilisée).
    let usedReason: FortiControllerSelection.Reason?
    let usedSort: Int
}

/// FortiGate des sites (tableau standard « reglages.fortigate.controleurs »).
struct RegFortiControllerTable: View {
    @ObservedObject private var fortigate = FortiGateStore.shared
    @EnvironmentObject private var state: AppState
    @ObservedObject var table: StandardTableModel<RegFortiControllerRow>
    @Binding var selection: UUID?
    let edit: (FortiGateController?) -> Void
    let remove: (FortiGateController) -> Void

    static let rowHeight: CGFloat = 30

    static let columns: [StandardColumn] = [
        StandardColumn(id: "ordre", title: "N°"),
        StandardColumn(id: "site", title: "Site", isRequired: true),
        StandardColumn(id: "fortigate", title: "FortiGate"),
        StandardColumn(id: "plages", title: "Plages couvertes"),
        StandardColumn(id: "jeton", title: "Jeton"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "test", title: "Dernier test"),
        StandardColumn(id: "utilisee", title: "Utilisée", isDefaultVisible: false),
        StandardColumn(id: "vdom", title: "VDOM", isDefaultVisible: false),
        StandardColumn(id: "modele", title: "Modèle", isDefaultVisible: false),
        StandardColumn(id: "switchs", title: "FortiSwitch", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegFortiControllerRow>] = [
        "ordre": KeyPathComparator(\RegFortiControllerRow.order),
        "site": KeyPathComparator(\RegFortiControllerRow.site),
        "fortigate": KeyPathComparator(\RegFortiControllerRow.address),
        "plages": KeyPathComparator(\RegFortiControllerRow.rangesSort),
        "jeton": KeyPathComparator(\RegFortiControllerRow.tokenSort),
        "etat": KeyPathComparator(\RegFortiControllerRow.stateRank),
        "test": KeyPathComparator(\RegFortiControllerRow.lastTestSort),
        "utilisee": KeyPathComparator(\RegFortiControllerRow.usedSort),
        "vdom": KeyPathComparator(\RegFortiControllerRow.vdom),
        "modele": KeyPathComparator(\RegFortiControllerRow.model),
        "switchs": KeyPathComparator(\RegFortiControllerRow.switches),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegFortiControllerRow> {
        StandardTableModel(id: "reglages.fortigate.controleurs", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }

    @MainActor
    private func rows() -> [RegFortiControllerRow] {
        let selection = fortigate.lastRefresh != nil ? fortigate.selection : fortigate.previewSelection(state: state)
        let used = Set(selection.controllerIDs)
        return fortigate.controllers.enumerated().map { index, c in
            let r = fortigate.runtime[c.id]
            let token = fortigate.hasToken(c.id)
            let (text, tone, rank, help) = Self.stateLabel(c, runtime: r, hasToken: token, isDemo: fortigate.isDemo)
            let status = c.lastStatus
            return RegFortiControllerRow(id: c.id, order: index + 1, site: c.displayName, address: c.addressLabel, vdom: c.vdom,
                                         ranges: c.ranges, rangesSort: c.ranges.first ?? "~", hasToken: token, tokenSort: token ? 0 : 1,
                                         state: text, stateTone: tone, stateHelp: help, stateRank: rank,
                                         lastTest: status?.date ?? r?.lastAttempt, lastTestSort: status?.date ?? r?.lastAttempt ?? .distantPast,
                                         model: [status?.model, status?.version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                         switches: status?.switchCount ?? r?.report?.switches.count ?? 0,
                                         isEnabled: c.isEnabled, isUsed: used.contains(c.id), usedReason: selection.pick(for: c.id)?.reason,
                                         usedSort: used.contains(c.id) ? 0 : 1)
        }
        .sorted(using: table.sortOrder)
    }

    /// État affiché d'une FortiGate (texte, couleur, rang de tri, explication).
    static func stateLabel(_ c: FortiGateController, runtime r: FortiGateStore.Runtime?, hasToken: Bool, isDemo: Bool) -> (String, Tone, Int, String) {
        if r?.busy == true { return ("Test…", .accent, 1, "Lecture en cours.") }
        if !c.isEnabled { return ("Désactivée", .neutral, 6, "Jamais lue tant qu’elle est désactivée.") }
        if !hasToken { return ("Jeton manquant", .warning, 4, "Modifiez la FortiGate pour coller le jeton de son administrateur API REST.") }
        if r?.pending != nil { return ("Empreinte à accepter", .warning, 3, "Vérifiez l’empreinte du certificat ci-dessous puis acceptez-la.") }
        switch c.lastStatus?.kind {
        case .ok?:
            let s = c.lastStatus
            let detail = [s?.hostname, s?.version].compactMap { $0 }.joined(separator: " · ")
            return ("Connectée", .success, 0, detail.isEmpty ? "Dernière lecture réussie." : "Dernière lecture réussie\u{00A0}: \(detail).")
        case .error?: return ("Erreur", .critical, 2, c.lastStatus?.message ?? "")
        case .certificate?: return ("Certificat", .warning, 3, c.lastStatus?.message ?? "")
        case .missingToken?: return ("Jeton manquant", .warning, 4, "Jeton absent au dernier test.")
        default:
            if c.pinnedFingerprint == nil { return ("À tester", .neutral, 5, "Premier contact\u{00A0}: «\u{00A0}Tester\u{00A0}» présentera l’empreinte du certificat à accepter.") }
            return ("À tester", .neutral, 5, c.lastStatus?.message.isEmpty == false ? c.lastStatus!.message : "Pas encore testée.")
        }
    }

    /// Libellé de la raison du choix (colonne « Utilisée »).
    static func usedLabel(_ reason: FortiControllerSelection.Reason?) -> (String, String) {
        switch reason {
        case .macAddress?: return ("Adresse de ce Mac", "Aucune plage scannée n’est couverte\u{00A0}: choisie parce qu’elle couvre l’adresse de ce Mac.")
        case .noRanges?: return ("Toutes (sans plage)", "Aucune FortiGate n’a de plage couverte\u{00A0}: toutes celles activées sont lues.")
        case .activeSite?: return ("Site actif", "FortiGate associée au site actif (Réglages › Sites et plages)\u{00A0}: la plage IP ne sert pas au choix.")
        default: return ("Plages scannées", "Une de ses plages couvertes contient ou chevauche une plage scannée.")
        }
    }

    /// Le tableau suit l'ordre de la liste : « Monter » et « Descendre » ont un effet visible.
    private var sortedByOrder: Bool { table.currentSort?.column == "ordre" }

    var body: some View {
        let rows = rows()
        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("N°", sortUsing: table.sort("ordre")) { row in
                RegSwitchCell("\(row.order)", mono: true, secondary: true)
                    .help("Position dans la liste\u{00A0}: à précision égale, la première de la liste l’emporte.")
            }
            .width(min: 30, ideal: 34, max: 50)
            .customizationID("ordre")

            TableColumn("SITE", sortUsing: table.sort("site")) { row in
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 12))
                        .foregroundStyle(row.isEnabled ? SwitchSource.fortigate.colors.foreground : Theme.textTertiary)
                    Text(row.site).font(Theme.bodySemibold).foregroundStyle(row.isEnabled ? Theme.text : Theme.textSecondary).lineLimit(1)
                }
                .frame(height: Self.rowHeight - 8)
            }
            .width(min: 90, ideal: 155)
            .customizationID("site")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("FORTIGATE", sortUsing: table.sort("fortigate")) { row in
                RegSwitchCell(row.address + (row.vdom.isEmpty ? "" : " · \(row.vdom)"), mono: true)
            }
            .width(min: 75, ideal: 135)
            .customizationID("fortigate")

            TableColumn("PLAGES COUVERTES", sortUsing: table.sort("plages")) { row in
                StandardTagList(tags: row.ranges, empty: "à renseigner")
            }
            .width(min: 80, ideal: 132)
            .customizationID("plages")

            TableColumn("JETON", sortUsing: table.sort("jeton")) { row in
                Chip(text: row.hasToken ? "Enregistré" : "Manquant", tone: row.hasToken ? .success : .warning,
                     systemImage: row.hasToken ? "lock.fill" : "lock.open")
                    .help(row.hasToken ? "Au Trousseau (service com.danymenard.netscope.fortigate, compte propre à cette FortiGate)." : "Aucun jeton au Trousseau pour cette FortiGate.")
            }
            .width(min: 64, ideal: 90)
            .customizationID("jeton")

            TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                Chip(text: row.state, tone: row.stateTone)
                    .help(row.stateHelp)
            }
            .width(min: 70, ideal: 100)
            .customizationID("etat")

            TableColumn("DERNIER TEST", sortUsing: table.sort("test")) { row in
                RegSwitchCell(row.lastTest.map { SwitchText.ago($0) } ?? "", secondary: true)
                    .help(row.lastTest.map { "Le \(SwitchText.dateTime($0))" } ?? "Jamais testée")
            }
            .width(min: 66, ideal: 95)
            .customizationID("test")

            TableColumn("UTILISÉE", sortUsing: table.sort("utilisee")) { row in
                if row.isUsed {
                    let (text, help) = Self.usedLabel(row.usedReason)
                    Chip(text: text, tone: .accent).help(help)
                } else {
                    RegSwitchCell("")
                }
            }
            .width(min: 80, ideal: 110)
            .customizationID("utilisee")
            .defaultVisibility(.hidden)

            // Au-delà de dix colonnes, le constructeur de Table demande un groupe.
            Group {
                TableColumn("VDOM", sortUsing: table.sort("vdom")) { row in
                    RegSwitchCell(row.vdom, mono: true)
                }
                .width(min: 50, ideal: 70)
                .customizationID("vdom")
                .defaultVisibility(.hidden)

                TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                    RegSwitchCell(row.model, secondary: true)
                }
                .width(min: 90, ideal: 150)
                .customizationID("modele")
                .defaultVisibility(.hidden)

                TableColumn("FORTISWITCH", sortUsing: table.sort("switchs")) { row in
                    RegSwitchCell(row.switches > 0 ? "\(row.switches)" : "", mono: true)
                }
                .width(min: 60, ideal: 80)
                .customizationID("switchs")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let c = fortigate.controller(id) {
                Button("Modifier…") { edit(c) }
                Button(c.isEnabled ? "Désactiver" : "Activer") { fortigate.setEnabled(id, !c.isEnabled, state: state) }
                Divider()
                // Sans tri par ordre, déplacer une ligne ne se verrait pas : triez par « N° ».
                Button("Monter") { fortigate.move(id, by: -1) }
                    .disabled(!sortedByOrder || fortigate.controllers.first?.id == id)
                Button("Descendre") { fortigate.move(id, by: 1) }
                    .disabled(!sortedByOrder || fortigate.controllers.last?.id == id)
                if !sortedByOrder {
                    Text("Triez par «\u{00A0}N°\u{00A0}» pour changer l’ordre")
                }
                Divider()
                Button("Copier les réponses brutes (diagnostic)") { fortigate.copyDiagnostic(id) }
                    .disabled((fortigate.runtime[id]?.calls ?? []).isEmpty)
                Divider()
                Button("Supprimer…", role: .destructive) { remove(c) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let c = fortigate.controller(id) { edit(c) }
        }
        .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: 12, headerHeight: RegSwitchTableMetrics.headerHeight, extra: 16)
    }
}

// MARK: - Petits éléments communs à la section et à la feuille

/// Empreinte SHA-256 affichée en monospace, sélectionnable.
struct RegFingerprintText: View {
    let fingerprint: String

    var body: some View {
        Text(FortiCertificatePin.display(fingerprint))
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
    }
}

/// Bilan des appels d'une lecture : adresses absentes de cette version ou refusées.
struct RegFortiCallsSummary: View {
    let calls: [FortiCallRecord]

    var body: some View {
        let missing = calls.filter { $0.outcome == .absent }
        let refused = calls.filter { $0.outcome == .refused || $0.outcome == .failed }
        if !missing.isEmpty || !refused.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(refused, id: \.path) { call in
                    // Refusé : droit du profil ou hôte de confiance ; échec : délai, réseau ou réponse illisible.
                    Text((call.outcome == .refused ? "Refusé" : "Échec") + "\u{00A0}: \(call.path)"
                         + (call.status.map { " (HTTP \($0))" } ?? "") + (call.message.isEmpty ? "" : " — \(call.message)"))
                        .font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !missing.isEmpty {
                    Text("Absent de cette version de FortiOS (ignoré)\u{00A0}: " + missing.map(\.path).joined(separator: ", "))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - FortiSwitch lus par une FortiGate

/// Ligne du tableau des FortiSwitch lus par la FortiGate.
struct RegFortiSwitchRow: Identifiable {
    let id: String
    let name: String
    let model: String
    let serial: String
    let firmware: String
    let address: String
    let addressSort: UInt32
    let status: String
    /// Rang de l'état, pour le tri et la couleur : 0 connecté et autorisé, 1 connecté,
    /// 2 découvert ou non autorisé (inutilisable), 3 déconnecté.
    let statusRank: Int
    let ports: String
    /// Nombre de ports actifs (tri de la colonne « Ports actifs »).
    let portsSort: Int
    let devices: Int

    var statusTone: Tone {
        switch statusRank {
        case 0, 1: return .success
        case 2: return .warning
        default: return .critical
        }
    }
}

/// FortiSwitch lus par la FortiGate (tableau standard « reglages.fortiswitch »).
struct RegFortiSwitchTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var table: StandardTableModel<RegFortiSwitchRow>
    let report: FortiGateReport
    /// FortiGate dont viennent ces FortiSwitch : deux sites peuvent avoir un switch du même nom.
    let controllerID: UUID

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "logiciel", title: "Logiciel"),
        StandardColumn(id: "adresse", title: "Adresse FortiLink"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "appareils", title: "Appareils détectés"),
        StandardColumn(id: "serie", title: "Numéro de série", isDefaultVisible: false),
        StandardColumn(id: "ports", title: "Ports actifs", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegFortiSwitchRow>] = [
        "nom": KeyPathComparator(\RegFortiSwitchRow.name),
        "modele": KeyPathComparator(\RegFortiSwitchRow.model),
        "logiciel": KeyPathComparator(\RegFortiSwitchRow.firmware),
        "adresse": KeyPathComparator(\RegFortiSwitchRow.addressSort),
        "etat": KeyPathComparator(\RegFortiSwitchRow.statusRank),
        "appareils": KeyPathComparator(\RegFortiSwitchRow.devices),
        "serie": KeyPathComparator(\RegFortiSwitchRow.serial),
        "ports": KeyPathComparator(\RegFortiSwitchRow.portsSort),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegFortiSwitchRow> {
        StandardTableModel(id: "reglages.fortiswitch", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    var body: some View {
        let located = report.locatedDevices
        let rows = report.switches.map { sw -> RegFortiSwitchRow in
            let up = sw.ports.filter { $0.linkUp == true }.count
            let status: String
            let rank: Int
            switch (sw.connected, sw.state?.lowercased()) {
            case (false?, _): (status, rank) = ("Déconnecté", 3)
            case (_, "authorized"?): (status, rank) = ("Connecté · autorisé", 0)
            case (_, "discovered"?): (status, rank) = ("Découvert · à autoriser", 2)
            case (_, "unauthorized"?), (_, "deauthorized"?): (status, rank) = ("Non autorisé", 2)
            default: (status, rank) = ("Connecté", 1)
            }
            return RegFortiSwitchRow(id: sw.switchID, name: sw.name, model: sw.model.isEmpty ? "FortiSwitch" : sw.model, serial: sw.serial,
                                     firmware: sw.firmware, address: sw.fortilinkIP?.description ?? "—",
                                     addressSort: sw.fortilinkIP?.value ?? .max, status: status, statusRank: rank,
                                     ports: "\(up) / \(sw.ports.count)", portsSort: up,
                                     devices: located.filter { sw.keys.contains($0.switchID.lowercased()) }.count)
        }
        .sorted(using: table.sortOrder)
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(row.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 110, ideal: 140)
            .customizationID("nom")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                RegSwitchCell(row.model, secondary: true)
            }
            .width(min: 90, ideal: 110)
            .customizationID("modele")

            TableColumn("LOGICIEL", sortUsing: table.sort("logiciel")) { row in
                RegSwitchCell(row.firmware, mono: true)
            }
            .width(min: 60, ideal: 80)
            .customizationID("logiciel")

            TableColumn("ADRESSE FORTILINK", sortUsing: table.sort("adresse")) { row in
                RegSwitchCell(row.address, mono: true)
                    .help("Adresse sur le réseau FortiLink, non joignable depuis ce Mac\u{00A0}: le switch est lu par la FortiGate.")
            }
            .width(min: 90, ideal: 120)
            .customizationID("adresse")

            TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                Chip(text: row.status, tone: row.statusTone)
            }
            .width(min: 80, ideal: 100)
            .customizationID("etat")

            TableColumn("APPAREILS", sortUsing: table.sort("appareils")) { row in
                RegSwitchCell("\(row.devices)", mono: true)
            }
            .width(min: 70, ideal: 110)
            .customizationID("appareils")

            TableColumn("NUMÉRO DE SÉRIE", sortUsing: table.sort("serie")) { row in
                RegSwitchCell(row.serial, mono: true)
            }
            .width(min: 100, ideal: 140)
            .customizationID("serie")
            .defaultVisibility(.hidden)

            TableColumn("PORTS ACTIFS", sortUsing: table.sort("ports")) { row in
                RegSwitchCell(row.ports, mono: true)
            }
            .width(min: 60, ideal: 90)
            .customizationID("ports")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegFortiSwitchRow.ID.self) { ids in
            if let id = ids.first, let host = host(of: id) {
                Button("Ouvrir dans «\u{00A0}Switchs et ports\u{00A0}»") {
                    SwitchStore.shared.select(host: host)
                    state.open(.switchs)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let host = host(of: id) {
                SwitchStore.shared.select(host: host)
                state.open(.switchs)
            }
        }
        .frame(height: RegSwitchTableMetrics.height(rows: rows.count))
    }

    /// Adresse du relevé affiché pour ce FortiSwitch dans « Switchs et ports » : même nom et même
    /// site (libellé marqué sur les relevés par FortiMulti), jamais le switch homonyme d'un autre site.
    @MainActor
    private func host(of id: String) -> String? {
        guard let sw = report.switches.first(where: { $0.switchID == id }) else { return nil }
        let named = SwitchStore.shared.controllerSnapshots.filter { $0.system.name == sw.name }
        if let label = FortiGateStore.shared.sites.first(where: { $0.controllerID == controllerID })?.label {
            return named.first { $0.controllerName == label }?.host.description
        }
        // Site absent de la dernière lecture : seulement si le nom est sans ambiguïté.
        return named.count == 1 ? named[0].host.description : nil
    }
}
