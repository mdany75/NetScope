import AppKit
import NetScopeCore
import SwiftUI

// Note 6 : ports RustDesk dans les ports ouverts (Scanner, fiche Appareil). Connexions TCP vers
// le serveur seulement sur clic de « Tester le serveur RustDesk » ; rien en démonstration.

/// Test d'un serveur RustDesk (connexions TCP sur 21115 à 21119), par appareil.
@MainActor
final class RustDeskServerTestModel: ObservableObject {
    static let shared = RustDeskServerTestModel()

    @Published private(set) var reports: [String: RustDeskPorts.ServerReport] = [:]
    @Published private(set) var running: Set<String> = []
    @Published private(set) var testedAt: [String: Date] = [:]

    private init() {
        if Launcher.isDemo { RustDeskPortsDemo.preload(self) }
    }

    func report(for host: String) -> RustDeskPorts.ServerReport? { reports[host] }
    func isRunning(_ host: String) -> Bool { running.contains(host) }

    func store(_ report: RustDeskPorts.ServerReport, for host: String, at date: Date = Date()) {
        reports[host] = report
        testedAt[host] = date
    }

    func test(host: String) {
        guard !running.contains(host) else { return }
        guard !Launcher.isDemo else {
            store(RustDeskPortsDemo.report(for: host), for: host)
            return
        }
        running.insert(host)
        Task { [weak self] in
            let options = PortScanOptions(timeout: 2, concurrency: 5, grabBanners: false)
            let summary = await PortScanner.scan(host: host, ports: RustDeskPorts.serverTestPorts, options: options)
            await MainActor.run {
                guard let self else { return }
                self.running.remove(host)
                self.store(RustDeskPorts.ServerReport(results: summary.results), for: host)
            }
        }
    }
}

enum RustDeskOpen {
    /// Ouvre une session directe dans RustDesk ; message d'erreur si le client n'est pas installé.
    @discardableResult
    static func direct(host: String, report: (String, Tone) -> Void) -> Bool {
        guard let url = RustDeskPorts.directURL(host: host) else {
            report("Adresse invalide pour RustDesk\u{00A0}: \(host)", .warning)
            return false
        }
        if Launcher.isDemo {
            report("Démonstration\u{00A0}: \(url.absoluteString) n’est pas ouvert.", .neutral)
            return false
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            report("RustDesk n’est pas installé sur ce Mac (rustdesk.com).", .warning)
            return false
        }
        NSWorkspace.shared.open(url)
        report("Ouverture dans RustDesk\u{00A0}: \(host)", .success)
        return true
    }
}

/// Pastille d'un port RustDesk du panneau de détail du Scanner : 21118 d'un poste ouvre une session
/// directe ; les ports d'un serveur ouvrent une bulle (rôle des ports, test du serveur).
struct ScanRustDeskPortButton: View {
    let port: UInt16
    let device: Device
    var report: (String, Tone) -> Void
    @State private var showsDetail = false

    private var role: RustDeskPorts.Role? { RustDeskPorts.role(openPorts: device.openPorts) }
    private var opensSession: Bool { port == RustDeskPorts.direct && role == .client }

    var body: some View {
        Button {
            if opensSession { RustDeskOpen.direct(host: device.ip.description, report: report) } else { showsDetail = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: opensSession ? "arrow.up.right.square" : "info.circle").font(.system(size: 11))
                Text(RustDeskPorts.buttonLabel(port))
                Text(service).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(ScanOutlineButtonStyle())
        .help(RustDeskPorts.help(port: port, role: role))
        .popover(isPresented: $showsDetail, arrowEdge: .leading) {
            RustDeskServerDetail(device: device).frame(width: 340).padding(14)
        }
    }

    /// « ID », « RELAIS »… ; 21118 d'un serveur est le WebSocket de hbbs, pas l'accès direct.
    private var service: String {
        if port == RustDeskPorts.direct, role?.isServer == true { return "WS" }
        return ScanFormat.service(port)
    }
}

/// Rôle des ports RustDesk d'un appareil et test du serveur (bulle du Scanner, fiche Appareil).
struct RustDeskServerDetail: View {
    let device: Device
    var showsHeader = true
    @ObservedObject private var tester = RustDeskServerTestModel.shared

    private var host: String { device.ip.description }
    private var role: RustDeskPorts.Role? { RustDeskPorts.role(openPorts: device.openPorts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(spacing: 8) {
                    Image(systemName: "display.2").foregroundStyle(Theme.accent)
                    Text(role?.label ?? "Ports RustDesk").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                }
                if let role {
                    Text(role.finding).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.port) { row in
                    portRow(row)
                }
                udpRow
            }
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            HStack(spacing: 8) {
                Button(tester.isRunning(host) ? "Test en cours…" : "Tester le serveur RustDesk") { tester.test(host: host) }
                    .buttonStyle(.secondary)
                    .disabled(tester.isRunning(host))
                    .help("Connexions TCP vers \(host) sur 21115 à 21119 (rien n’est envoyé)")
                if let date = tester.testedAt[host] {
                    Text("Testé à \(ToolText.time(date))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if let report = tester.report(for: host) {
                verdict(report)
            }
        }
    }

    private struct Row { let port: UInt16; let state: PortState?; let rttMs: Double? }

    /// Ports du dernier test s'il existe, sinon ceux connus du scan (ouvert ou non vérifié).
    private var rows: [Row] {
        if let report = tester.report(for: host) {
            return report.lines.map { Row(port: $0.port, state: $0.state, rttMs: $0.rttMs) }
        }
        return RustDeskPorts.tcpPorts.map { Row(port: $0, state: device.openPorts.contains($0) ? .open : nil, rttMs: nil) }
    }

    private func portRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "TCP \(row.port)").font(Theme.mono(11, weight: .semibold)).frame(width: 74, alignment: .leading)
            Text(RustDeskPorts.info(row.port).map { "\($0.component) · \($0.role)" } ?? "")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            stateChip(row)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var udpRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: "UDP 21116").font(Theme.mono(11, weight: .semibold)).frame(width: 74, alignment: .leading)
            Text("hbbs · battement de cœur et percée NAT").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Chip(text: "non vérifié", tone: .neutral)
                .help("Un scan TCP ne vérifie pas l’UDP\u{00A0}: le contrôler sur le pare-feu (redirection UDP 21116).")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func stateChip(_ row: Row) -> some View {
        switch row.state {
        case .open?: Chip(text: row.rttMs.map { "ouvert · \(ToolFormat.milliseconds($0))" } ?? "ouvert", tone: .success)
        case .closed?: Chip(text: "fermé", tone: row.port == RustDeskPorts.relayWebSocket || row.port == RustDeskPorts.direct ? .neutral : .warning)
        case .filtered?: Chip(text: "filtré", tone: row.port == RustDeskPorts.relayWebSocket || row.port == RustDeskPorts.direct ? .neutral : .warning)
        case nil: Chip(text: "non vérifié", tone: .neutral)
        }
    }

    private func verdict(_ report: RustDeskPorts.ServerReport) -> some View {
        let tone: Tone = {
            switch report.verdict {
            case .ok: return .success
            case .noRelay, .relayOnly: return .warning
            case .unreachable: return .critical
            }
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.title).font(Theme.bodySemibold).foregroundStyle(tone.foreground)
                Text(report.message).font(Theme.small).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }
}

/// Constat RustDesk de la fiche Appareil (carte « Services connus »).
struct RustDeskDeviceFinding: View {
    let device: Device
    @State private var message: (String, Tone)?

    var body: some View {
        if let role = RustDeskPorts.role(openPorts: device.openPorts) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Chip(text: role.label, tone: .accent, systemImage: "display.2")
                    if case .server(confirmed: false) = role {
                        Text("à confirmer").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                if role == .client {
                    Text(role.finding).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        RustDeskOpen.direct(host: device.ip.description) { message = ($0, $1) }
                    } label: {
                        Label("Ouvrir dans RustDesk", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.secondary)
                    .help(RustDeskPorts.directURL(host: device.ip.description)?.absoluteString ?? "")
                    if let message {
                        Text(message.0).font(Theme.caption).foregroundStyle(message.1.foreground)
                    }
                } else {
                    Text(role.finding).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    RustDeskServerDetail(device: device, showsHeader: false)
                }
            }
            .padding(.top, 2)
        }
    }
}
