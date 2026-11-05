import NetScopeCore
import SwiftUI

/// Profils de ports proposés (croquis : Rapide, Courant, Complet, Imprimantes, Caméras ; note 6 :
/// Accès distant, avec RustDesk 21115 à 21119).
enum ToolPortProfile: String, CaseIterable, Identifiable {
    case rapide, courant, complet, imprimantes, cameras, accesDistant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rapide: return "Rapide (\(ScanProfile.commonPorts.count) courants)"
        case .courant: return "Courant"
        case .complet: return "Complet"
        case .imprimantes: return "Imprimantes"
        case .cameras: return "Caméras"
        case .accesDistant: return "Accès distant (RustDesk)"
        }
    }

    var ports: String {
        switch self {
        case .rapide: return ScanProfile.commonPorts.map(String.init).joined(separator: ", ")
        case .courant: return "1-1024, 3389, 5900, 8080, 8443, 9100"
        case .complet: return "1-65535"
        case .imprimantes: return "80, 443, 515, 631, 9100"
        case .cameras: return "80, 443, 554, 8000, 8554, 37777"
        case .accesDistant: return "22, 23, 3389, 5900, 21115-21119"
        }
    }
}

/// Scan de ports d'un hôte : état observable, partagé entre la boîte à outils et la fiche appareil.
@MainActor
final class ToolPortScanModel: ObservableObject {
    @Published var target = ""
    @Published var portsText = ToolPortProfile.courant.ports
    @Published var profile: ToolPortProfile? = .courant
    @Published var grabBanners = true

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var openResults: [PortScanResult] = []
    @Published private(set) var summary: PortScanSummary?
    @Published private(set) var finishedAt: Date?
    @Published var error: String?

    private var task: Task<Void, Never>?
    /// Numéro du scan en cours : un scan annulé et remplacé ne doit plus toucher à l'état.
    private var generation = 0

    init(target: String = "") {
        self.target = target
    }

    var parsedPorts: [UInt16]? { ScanProfile.parsePorts(portsText) }

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    func choose(_ profile: ToolPortProfile) {
        self.profile = profile
        portsText = profile.ports
    }

    /// Commande équivalente pour l'historique.
    var command: String {
        let ports = portsText.replacingOccurrences(of: " ", with: "")
        return "scan " + (grabBanners ? "-sV " : "") + "-p \(ports) \(target.trimmingCharacters(in: .whitespaces))"
    }

    func start(store: ToolStore, onFinish: (@MainActor (PortScanSummary) -> Void)? = nil) {
        let host = target.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { error = "Saisir une adresse IP ou un nom d’hôte."; return }
        guard host.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else {
            error = "« \(host) » n’est pas une adresse ou un nom d’hôte valide."
            return
        }
        guard let ports = parsedPorts, !ports.isEmpty else {
            error = "Liste de ports invalide (exemple\u{00A0}: 22, 80, 8000-8100)."
            return
        }
        error = nil
        task?.cancel()
        generation += 1
        let run = generation
        isRunning = true
        done = 0
        total = ports.count
        openResults = []
        summary = nil
        store.record(command: command)
        let options = PortScanOptions(timeout: 1.5, concurrency: ports.count > 2000 ? 128 : 64, grabBanners: grabBanners)
        let model = self
        task = Task { [weak self] in
            let result = await PortScanner.scan(host: host, ports: ports, options: options) { finished, count, latest in
                guard latest.state == .open || finished % 32 == 0 || finished == count else { return }
                Task { @MainActor in model.progress(finished, latest, run: run) }
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == run else { return }
                self.isRunning = false
                self.done = result.scannedCount
                self.summary = result
                self.openResults = result.open
                self.finishedAt = Date()
                let status: ToolRecent.Status = result.wasCancelled ? .info : .ok
                let ports = result.open.prefix(6).map { String($0.port) }.joined(separator: ", ")
                let text = result.open.isEmpty ? result.summary : "\(result.open.count) ouverts\u{00A0}: \(ports)" + (result.open.count > 6 ? "…" : "")
                store.record(ToolRecent(tool: .ports, target: host, summary: result.wasCancelled ? "Interrompu · " + text : text, status: status))
                onFinish?(result)
            }
        }
    }

    private func progress(_ finished: Int, _ latest: PortScanResult, run: Int) {
        guard isRunning, run == generation else { return }
        done = max(done, finished)
        if latest.state == .open, !openResults.contains(where: { $0.port == latest.port }) {
            openResults.append(latest)
            openResults.sort { $0.port < $1.port }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// Outil « Scan de ports ».
struct PortScanView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolPortScanModel
    @ObservedObject var store: ToolStore
    @StateObject private var table = PortResultsTable.makeModel(id: "outils.ports", showProto: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Cible (IP ou hostname)") {
                    ToolTextField(placeholder: "10.182.122.111", text: $model.target) { model.start(store: store) }
                        .frame(minWidth: 170)
                }
                ToolLabeledField(label: "Plage de ports") {
                    ToolTextField(placeholder: "1-1024, 3389", text: $model.portsText,
                                  invalid: model.parsedPorts == nil) { model.start(store: store) }
                        .frame(minWidth: 170)
                        .help(model.portsText)
                        .onChange(of: model.portsText) { _, text in
                            if model.profile?.ports != text { model.profile = nil }
                        }
                }
            }
            // Profils, case et bouton sur une ligne ; en petite fenêtre, la case et le bouton passent dessous.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    profiles.fixedSize()
                    Spacer(minLength: 0)
                    launchControls
                }
                VStack(alignment: .leading, spacing: 10) {
                    profiles
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        launchControls
                    }
                }
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.isRunning || model.summary != nil {
                progressBlock
                PortResultsTable(host: model.target.trimmingCharacters(in: .whitespaces), results: tableRows,
                                 table: table, probedAt: model.isRunning ? nil : model.finishedAt)
                hostFooter
            } else {
                Text("Choisissez un profil ou saisissez une liste (22, 80, 8000-8100), puis lancez le scan. Les ports sont testés en TCP\u{00A0}; une bannière est lue sur SSH, FTP, SMTP et HTTP.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if model.target.isEmpty { model.target = state.selectedDevice?.ip.description ?? "" }
        }
    }

    private var profiles: some View {
        ToolFlowLayout(spacing: 6) {
            Text("Profil\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 24)
            ForEach(ToolPortProfile.allCases) { profile in
                ToolChoiceChip(label: profile.label, isSelected: model.profile == profile, mono: false) { model.choose(profile) }
            }
        }
    }

    private var launchControls: some View {
        HStack(spacing: 12) {
            ToolCheckbox(label: "Détection de services", isOn: $model.grabBanners).fixedSize()
            Group {
                if model.isRunning {
                    Button("Arrêter") { model.cancel() }.buttonStyle(.secondary)
                } else {
                    Button("Lancer le scan") { model.start(store: store) }.buttonStyle(.primary)
                }
            }
            .fixedSize()
        }
    }

    private var tableRows: [PortScanResult] {
        guard let summary = model.summary else { return model.openResults }
        // Quelques ports filtrés sont utiles (pare-feu) ; une longue liste ne l'est pas.
        let filtered = summary.results.filter { $0.state == .filtered }
        return (summary.open + (filtered.count <= 8 ? filtered : [])).sorted { $0.port < $1.port }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.isRunning {
                    Text("En cours · \(ToolFormat.integer(model.done)) / \(ToolFormat.integer(model.total)) ports · \(model.openResults.count) ouverts")
                } else if let summary = model.summary {
                    Text((summary.wasCancelled ? "Interrompu · " : "Terminé · ") + summary.summary)
                }
                Spacer()
                if let summary = model.summary {
                    Text(ToolFormat.seconds(summary.duration)).font(Theme.mono(12))
                }
                ToolColumnsMenu(model: table)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            ProgressBar(fraction: model.isRunning ? model.fraction : 1,
                        color: model.isRunning ? Theme.accent : Theme.success)
        }
    }

    @ViewBuilder private var hostFooter: some View {
        let host = model.target.trimmingCharacters(in: .whitespaces)
        if let device = state.devices.first(where: { $0.ip.description == host || $0.hostname == host }) {
            HStack(spacing: 0) {
                Text("Hôte\u{00A0}: ").foregroundStyle(Theme.textSecondary)
                Button(device.ip.description) { state.showDevice(device.id) }
                    .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.accent)
                Text(" · " + [device.displayName, device.mac?.formatted(.upperColon), device.switchLocation, device.vlan.map { "VLAN \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.small)
        }
    }
}

/// Tableau des ports (tableau standard, note 8) : port, état, service, bannière, délai, action ;
/// facultatives : protocole, adresse web, heure du relevé. Partagé par l'outil (« outils.ports ») et
/// l'onglet Ports et services de la fiche appareil (« appareil.ports ») : chacun garde son modèle.
struct PortResultsTable: View {
    @EnvironmentObject private var appState: AppState
    let host: String
    let results: [PortScanResult]
    @ObservedObject var table: StandardTableModel<PortScanResult>
    /// Heure du scan qui a produit les lignes (nil : scan en cours ou ports connus de l'inventaire).
    var probedAt: Date? = nil
    var emptyText = "Aucun port ouvert pour l’instant."

    /// Colonnes ; `showProto` rend la colonne Proto visible par défaut (fiche appareil, comme le croquis).
    static func columns(showProto: Bool) -> [StandardColumn] {
        [
            StandardColumn(id: "port", title: "Port", isRequired: true),
            StandardColumn(id: "proto", title: "Proto", isDefaultVisible: showProto),
            StandardColumn(id: "etat", title: "État"),
            StandardColumn(id: "service", title: "Service"),
            StandardColumn(id: "banniere", title: "Bannière / version"),
            StandardColumn(id: "delai", title: "Délai"),
            StandardColumn(id: "action", title: "Action"),
            StandardColumn(id: "url", title: "Adresse web", isDefaultVisible: false),
            StandardColumn(id: "releve", title: "Relevé à", isDefaultVisible: false),
        ]
    }

    static let sortKeys: [String: KeyPathComparator<PortScanResult>] = [
        "port": KeyPathComparator(\PortScanResult.port),
        "proto": KeyPathComparator(\PortScanResult.toolSortProto),
        "etat": KeyPathComparator(\PortScanResult.toolSortState),
        "service": KeyPathComparator(\PortScanResult.toolSortService),
        "banniere": KeyPathComparator(\PortScanResult.toolSortBanner),
        "delai": KeyPathComparator(\PortScanResult.toolSortDelay),
        "url": KeyPathComparator(\PortScanResult.toolSortWeb),
    ]

    @MainActor
    static func makeModel(id: String, showProto: Bool) -> StandardTableModel<PortScanResult> {
        StandardTableModel(id: id, columns: columns(showProto: showProto), sortKeys: sortKeys, defaultSort: "port")
    }

    private var protoVisibility: Visibility {
        table.columns.first { $0.id == "proto" }?.isDefaultVisible == true ? .automatic : .hidden
    }

    var body: some View {
        let rows = results.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: rows.count, emptyText: emptyText) {
            Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("PORT", sortUsing: table.sort("port")) { result in
                    ToolTableText(String(result.port), weight: .semibold)
                }
                .width(min: 50, ideal: 58)
                .customizationID("port")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("PROTO", sortUsing: table.sort("proto")) { result in
                    ToolTableText(result.toolSortProto)
                }
                .width(min: 44, ideal: 56)
                .customizationID("proto")
                .defaultVisibility(protoVisibility)

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { result in
                    Chip(text: result.state.label, tone: result.state == .open ? .success : .warning)
                }
                .width(min: 56, ideal: 64)
                .customizationID("etat")

                TableColumn("SERVICE", sortUsing: table.sort("service")) { result in
                    ToolTableText(result.service ?? "—", color: result.service == nil ? Theme.textTertiary : Theme.text)
                }
                .width(min: 56, ideal: 72)
                .customizationID("service")

                TableColumn("BANNIÈRE / VERSION", sortUsing: table.sort("banniere")) { result in
                    ToolTableText(result.banner ?? (result.state == .filtered ? "Aucune réponse (pare-feu\u{00A0}?)" : "—"),
                                  color: Theme.textSecondary)
                        .help(result.banner ?? "")
                }
                .width(min: 100, ideal: 140)
                .customizationID("banniere")

                TableColumn("DÉLAI", sortUsing: table.sort("delai")) { result in
                    ToolTableText(result.rttMs.map(ToolFormat.milliseconds) ?? "—", alignment: .trailing)
                }
                .width(min: 44, ideal: 56)
                .customizationID("delai")

                TableColumn("ACTION") { result in
                    // Hauteur de ligne fixe : le bouton (28 pt) ne doit pas agrandir sa ligne.
                    action(result).frame(maxWidth: .infinity, maxHeight: ToolTableMetrics.cellHeight, alignment: .trailing)
                }
                .width(min: 50, ideal: 60)
                .customizationID("action")

                TableColumn("ADRESSE WEB", sortUsing: table.sort("url")) { result in
                    let url = webURL(result)
                    ToolTableText(url ?? "—", color: url == nil ? Theme.textTertiary : Theme.text)
                        .help(url ?? "")
                }
                .width(min: 90, ideal: 180)
                .customizationID("url")
                .defaultVisibility(.hidden)

                TableColumn("RELEVÉ À") { _ in
                    ToolTableText(probedAt.map { ToolText.time($0) } ?? "—",
                                  color: probedAt == nil ? Theme.textTertiary : Theme.textSecondary)
                }
                .width(min: 60, ideal: 90)
                .customizationID("releve")
                .defaultVisibility(.hidden)
            }
        }
    }

    /// Adresse web du port (http ou https), ou nil.
    private func webURL(_ result: PortScanResult) -> String? {
        guard result.state == .open, let scheme = PortScanner.webScheme(for: result.port) else { return nil }
        let defaultPort = (scheme == "http" && result.port == 80) || (scheme == "https" && result.port == 443)
        return "\(scheme)://\(host)" + (defaultPort ? "" : ":\(result.port)")
    }

    @ViewBuilder private func action(_ result: PortScanResult) -> some View {
        if let url = webURL(result) {
            Button("Ouvrir") { ToolActions.open(url) }
                .buttonStyle(.ghost)
        } else if result.state == .open, result.port == 22 || (result.banner?.hasPrefix("SSH-") ?? false) {
            // Note 52 : l'utilisateur est demandé avant d'ouvrir ssh user@ip (port non standard
            // repris quand la bannière annonce SSH).
            Button("SSH…") {
                var target = QuickLoginTarget(host: host, state: appState)
                if result.port != 22 { target.port = Int(result.port) }
                QuickLoginModel.shared.ask(target)
            }
            .buttonStyle(.ghost)
        } else {
            Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Clés de tri du tableau des ports (toujours Comparable).
extension PortScanResult {
    /// Seul TCP est scanné.
    var toolSortProto: String { "tcp" }
    var toolSortState: String { state.label }
    var toolSortService: String { service ?? "" }
    var toolSortBanner: String { banner ?? "" }
    /// Sans délai mesuré : en fin de liste.
    var toolSortDelay: Double { rttMs ?? .infinity }
    /// Ports web d'abord (http, https), puis par numéro.
    var toolSortWeb: String {
        guard let scheme = PortScanner.webScheme(for: port), state == .open else { return "~" }
        return scheme + String(format: "%05d", Int(port))
    }
}
