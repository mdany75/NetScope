import NetScopeCore
import SwiftUI

/// Profils de ports proposés (croquis : Rapide, Courant, Complet, Imprimantes, Caméras).
enum ToolPortProfile: String, CaseIterable, Identifiable {
    case rapide, courant, complet, imprimantes, cameras

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rapide: return "Rapide (30 courants)"
        case .courant: return "Courant"
        case .complet: return "Complet"
        case .imprimantes: return "Imprimantes"
        case .cameras: return "Caméras"
        }
    }

    var ports: String {
        switch self {
        case .rapide: return ScanProfile.commonPorts.map(String.init).joined(separator: ", ")
        case .courant: return "1-1024, 3389, 5900, 8080, 8443, 9100"
        case .complet: return "1-65535"
        case .imprimantes: return "80, 443, 515, 631, 9100"
        case .cameras: return "80, 443, 554, 8000, 8554, 37777"
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
                Task { @MainActor in model.progress(finished, latest) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
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

    private func progress(_ finished: Int, _ latest: PortScanResult) {
        guard isRunning else { return }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                ToolLabeledField(label: "Cible (IP ou hostname)") {
                    ToolTextField(placeholder: "10.182.122.111", text: $model.target) { model.start(store: store) }
                }
                ToolLabeledField(label: "Plage de ports") {
                    ToolTextField(placeholder: "1-1024, 3389", text: $model.portsText,
                                  invalid: model.parsedPorts == nil) { model.start(store: store) }
                        .onChange(of: model.portsText) { _, text in
                            if model.profile?.ports != text { model.profile = nil }
                        }
                }
            }
            HStack(alignment: .center, spacing: 12) {
                ToolFlowLayout(spacing: 6) {
                    Text("Profil\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 28)
                    ForEach(ToolPortProfile.allCases) { profile in
                        ToolChoiceChip(label: profile.label, isSelected: model.profile == profile, mono: false) { model.choose(profile) }
                    }
                }
                Spacer(minLength: 0)
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
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if model.isRunning || model.summary != nil {
                progressBlock
                PortResultsTable(host: model.target, results: tableRows, showProto: false)
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

/// Tableau des ports : port, état, service, bannière, délai, action.
struct PortResultsTable: View {
    let host: String
    let results: [PortScanResult]
    var showProto = true

    var body: some View {
        ToolTable(columns: columns) {
            if results.isEmpty {
                Text("Aucun port ouvert pour l’instant.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            ForEach(results) { result in
                ToolTableRow {
                    Text(verbatim: String(result.port)).font(Theme.mono(12, weight: .semibold)).toolCell(70)
                    if showProto { Text("tcp").font(Theme.mono(12)).toolCell(66) }
                    Chip(text: result.state.label, tone: result.state == .open ? .success : .warning).toolCell(80)
                    Text(result.service ?? "—").font(Theme.mono(12)).toolCell(100)
                    Text(result.banner ?? (result.state == .filtered ? "Aucune réponse (pare-feu ?)" : "—"))
                        .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).help(result.banner ?? "").toolCell(nil)
                    Text(result.rttMs.map(ToolFormat.milliseconds) ?? "—").font(Theme.mono(12)).toolCell(70, alignment: .trailing)
                    action(result).toolCell(90, alignment: .trailing)
                }
            }
        }
    }

    private var columns: [TableHeader.Column] {
        var list: [TableHeader.Column] = [.init(title: "Port", width: 70)]
        if showProto { list.append(.init(title: "Proto", width: 66)) }
        list += [.init(title: "État", width: 80), .init(title: "Service", width: 100), .init(title: "Bannière / version"),
                 .init(title: "Délai", width: 70, alignment: .trailing), .init(title: "Action", width: 90, alignment: .trailing)]
        return list
    }

    @ViewBuilder private func action(_ result: PortScanResult) -> some View {
        if result.state == .open, let scheme = PortScanner.webScheme(for: result.port) {
            let defaultPort = (scheme == "http" && result.port == 80) || (scheme == "https" && result.port == 443)
            Button("Ouvrir") { ToolActions.open("\(scheme)://\(host)" + (defaultPort ? "" : ":\(result.port)")) }
                .buttonStyle(.ghost)
        } else if result.state == .open, result.port == 22 {
            Button("SSH") { ToolActions.open("ssh://\(host)") }.buttonStyle(.ghost)
        } else {
            Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
        }
    }
}
