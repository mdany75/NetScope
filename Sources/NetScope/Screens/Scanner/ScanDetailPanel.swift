import AppKit
import NetScopeCore
import SwiftUI

/// Panneau de détail (≈ 360 pt) : identité, emplacement physique, latence, ports, actions rapides.
struct ScanDetailPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController

    var body: some View {
        if let device = state.selectedDevice {
            ScrollView {
                VStack(spacing: 12) {
                    ScanDetailIdentity(device: device).id(device.id)
                    ScanDetailLocation(device: device)
                    ScanDetailLatency(device: device, scan: scan)
                    ScanDetailActions(device: device, scan: scan)
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.never)
        } else {
            Panel {
                EmptyState(systemImage: "cursorarrow.click.2", title: "Aucun appareil sélectionné",
                           message: "Sélectionnez une ligne du tableau pour voir son détail.")
            }
            .frame(maxHeight: 260)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Identité

struct ScanDetailIdentity: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    @State private var name: String

    init(device: Device) {
        self.device = device
        _name = State(initialValue: device.customName ?? "")
    }

    private var statusTone: Tone { device.isOnline ? .success : .neutral }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.neutralSoft)
                        Image(systemName: ScanFormat.symbol(device.deviceType))
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Theme.neutralText)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                            .font(Theme.panelTitle)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(device.ip.description).font(Theme.mono(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                        HStack(spacing: 6) {
                            ScanPill(text: device.isOnline ? "En ligne" : "Hors ligne", tone: statusTone)
                            ScanPill(text: device.deviceType.label, tone: .neutral)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    KeyValueRow(key: "Hostname", value: device.hostnameLabel ?? "—", keyWidth: 110)
                    if let source = device.nameSourceLabel {
                        KeyValueRow(key: "Source du nom", value: source, keyWidth: 110)
                    }
                    KeyValueRow(key: "MAC", value: device.mac?.formatted(.upperColon) ?? "—", mono: true, keyWidth: 110)
                    KeyValueRow(key: "OUI", value: ouiLabel, keyWidth: 110)
                    KeyValueRow(key: "Découverte", value: ScanFormat.discovery(device), keyWidth: 110)
                    KeyValueRow(key: "Première vue", value: ScanFormat.date(device.firstSeen), keyWidth: 110)
                    HStack(spacing: 8) {
                        Text("Nom personnalisé")
                            .font(Theme.small)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 110, alignment: .leading)
                        TextField("", text: $name, prompt: Text("Ex. : Imprimante accueil").foregroundStyle(Theme.textTertiary))
                            .textFieldStyle(.plain)
                            .font(Theme.small)
                            .padding(.horizontal, 7)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                            .onSubmit { state.setCustomName(name, for: device.id) }
                            .onChange(of: name) { _, value in state.setCustomName(value, for: device.id) }
                    }
                    .padding(.top, 5)
                }
                .padding(.top, 12)
            }
        }
    }

    private var ouiLabel: String {
        guard let mac = device.mac else { return "—" }
        let oui = String(mac.formatted(.upperColon).prefix(8))
        if mac.isLocallyAdministered { return "\(oui) · Adresse administrée localement" }
        return "\(oui) · \(device.vendorLabel)"
    }
}

/// Pastille arrondie du croquis (« En ligne », « Imprimante »).
struct ScanPill: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.captionSemibold)
            .foregroundStyle(tone == .neutral ? Theme.neutralText : tone.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.background))
            .fixedSize()
    }
}

// MARK: - Emplacement physique

struct ScanDetailLocation: View {
    let device: Device
    @ObservedObject private var switches = SwitchStore.shared

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                ScanCardTitle(text: "Emplacement physique")
                HStack(spacing: 8) {
                    box("Switch", device.switchName ?? "—")
                    box("Port", device.switchPort ?? "—")
                    box("VLAN", device.vlan.map(String.init) ?? "—")
                }
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String {
        if device.switchPort == "Wi-Fi", let name = device.switchName { return "Client sans fil associé à \(name)" }
        if let name = device.switchName {
            let auto = switches.hosts.contains { switches.isAutoDiscovered($0) && switches.snapshots[$0]?.displayName == name }
            return "\(name) · table MAC SNMP" + (auto ? " · switch découvert automatiquement" : "")
        }
        guard let result = switches.autoResult else {
            return "Emplacement non relevé\u{00A0}: les switchs sont découverts en SNMP à la fin du scan."
        }
        if result.interrupted {
            return "Découverte des switchs interrompue\u{00A0}: relancez le scan pour localiser cet appareil."
        }
        if !result.foundSwitch {
            return "Aucun switch relevé au dernier scan\u{00A0}: voyez le bilan sous les plages à scanner."
        }
        if device.mac == nil { return "Adresse MAC inconnue\u{00A0}: impossible de retrouver le port dans les tables MAC." }
        return "Adresse MAC vue sur aucun port d’accès des switchs relevés (appareil derrière un switch non interrogé\u{00A0}?)."
    }

    private func box(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Latence et ports

struct ScanDetailLatency: View {
    let device: Device
    @ObservedObject var scan: ScanController

    private var history: [Double?] { scan.latencyHistory[device.id] ?? [] }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    ScanCardTitle(text: "Latence · 30 derniers pings")
                    Spacer(minLength: 6)
                    Text(summary).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    if history.count >= 2 {
                        Sparkline(values: history, color: Theme.accent, lineWidth: 1.6, filled: false)
                            .padding(.bottom, 1)
                    } else {
                        Text(scan.measuring.contains(device.id) ? "Mesure en cours…" : "Mesurez 30 pings (environ 10 s) pour tracer la courbe.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 44)
                .padding(.top, 8)
                HStack {
                    Spacer()
                    Button {
                        scan.measureLatency(of: device)
                    } label: {
                        Label(scan.measuring.contains(device.id) ? "Mesure… \(history.count)/30" : "Mesurer",
                              systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.ghost)
                    .disabled(scan.measuring.contains(device.id))
                }
                .padding(.top, 2)

                ScanCardTitle(text: "Ports ouverts").padding(.top, 8).padding(.bottom, 8)
                if device.openPorts.isEmpty {
                    Text(scan.probing.contains(device.id) ? "Scan approfondi des ports…" : "Aucun port ouvert détecté (profil \(profileLabel)).")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScanFlowLayout(spacing: 6) {
                        ForEach(device.openPorts, id: \.self) { port in
                            portButton(port)
                        }
                    }
                }
            }
        }
    }

    @EnvironmentObject private var state: AppState
    private var profileLabel: String { state.scanProfile.label }

    private var summary: String {
        let values = history.compactMap { $0 }
        if history.count >= 2 {
            guard !values.isEmpty else { return "Sans réponse" }
            let average = values.reduce(0, +) / Double(values.count)
            let loss = Int((Double(history.count - values.count) / Double(history.count) * 100).rounded())
            return "moy. \(ScanFormat.latency(average)) · perte \(loss) %"
        }
        guard let latency = device.latencyMs else { return device.isOnline ? "—" : "Sans réponse" }
        return ScanFormat.latency(latency)
    }

    private func portButton(_ port: UInt16) -> some View {
        let url = ScanFormat.url(for: port, ip: device.ip)
        return Button {
            if let url { ScanFormat.open(url) } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(device.ip):\(port)", forType: .string)
                scan.show("Copié : \(device.ip):\(port)", place: .actions)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: url == nil ? "doc.on.doc" : "arrow.up.right.square").font(.system(size: 11))
                Text(ScanFormat.portButtonLabel(port))
                Text(ScanFormat.service(port)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(ScanOutlineButtonStyle())
        .help(url.map { "Ouvrir \($0.absoluteString)" } ?? "Copier \(device.ip.description):\(port)")
    }
}

// MARK: - Actions rapides

struct ScanDetailActions: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    @ObservedObject var scan: ScanController

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                ScanCardTitle(text: "Actions rapides").padding(.bottom, 8)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    action("Ping continu", "waveform.path.ecg") { state.sendToPing(device.ip.description) }
                    action("Traceroute", "point.topleft.down.to.point.bottomright.curvepath") {}
                        .disabled(true)
                        .help("Bientôt : traceroute depuis la boîte à outils")
                    action(scan.probing.contains(device.id) ? "Scan des ports…" : "Scanner les ports", "square.grid.3x3") {
                        scan.probePorts(of: device, state: state)
                    }
                    .disabled(scan.probing.contains(device.id))
                    action("Wake-on-LAN", "power") { scan.wake(device, state: state) }
                        .disabled(device.mac == nil)
                    action("SSH", "terminal") { ScanFormat.open(URL(string: "ssh://\(device.ip)")!) }
                    action("Copier IP", "doc.on.doc") { scan.copy(device.ip.description, label: "IP") }
                    action("Copier MAC", "doc.on.doc") {
                        if let mac = device.mac { scan.copy(mac.formatted(.upperColon), label: "MAC") }
                    }
                    .disabled(device.mac == nil)
                    action("Voir le port", "rectangle.connected.to.line.below") { state.open(.switchs) }
                        .disabled(device.switchName == nil)
                }
                if let toast = scan.toast, toast.place == .actions {
                    ScanToastView(toast: toast).padding(.top, 8)
                }
                Button { state.showDevice(device.id) } label: {
                    HStack(spacing: 6) {
                        Text("Voir la fiche complète")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: scan.toast)
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(ScanOutlineButtonStyle(height: 34, font: .system(size: 12, weight: .medium), fullWidth: true))
    }
}
