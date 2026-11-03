import NetScopeCore
import SwiftUI

@MainActor
final class ToolWakeModel: ObservableObject {
    enum PortChoice: String, CaseIterable, Identifiable {
        case nine, seven, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nine: return "9 (discard)"
            case .seven: return "7 (echo)"
            case .both: return "9 et 7"
            }
        }
        var ports: [UInt16] {
            switch self {
            case .nine: return [9]
            case .seven: return [7]
            case .both: return [9, 7]
            }
        }
    }

    @Published var macText = ""
    @Published var broadcastText = ""
    @Published var port: PortChoice = .nine
    @Published var error: String?
    @Published private(set) var lastSent: String?

    /// Délai de vérification après l'envoi.
    static let verifyDuration: TimeInterval = 60

    var command: String {
        "wol \(macText.trimmingCharacters(in: .whitespaces).uppercased()) -b \(broadcastText) -p " + port.ports.map(String.init).joined(separator: ",")
    }

    /// Envoie le paquet magique ; si l'adresse IP du poste est connue, vérifie pendant 60 s qu'il répond.
    func wake(state: AppState, store: ToolStore) {
        guard let mac = MACAddress(macText) else {
            error = "MAC invalide\u{00A0}: 12 caractères hexadécimaux attendus."
            return
        }
        guard let broadcast = IPv4Address(broadcastText) else {
            error = "Adresse de broadcast invalide (exemple\u{00A0}: 10.182.122.255)."
            return
        }
        error = nil
        let device = state.devices.first { $0.mac == mac }
        let name = device?.hostnameLabel ?? device?.displayName ?? "Manuel"
        store.record(command: command)
        let destination = "\(broadcast):" + port.ports.map(String.init).joined(separator: ",")
        do {
            try WakeOnLAN.send(to: mac, broadcast: broadcast, ports: port.ports)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.error = message
            store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon), detail: message, status: .failed))
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac.formatted(.upperColon))", summary: message, status: .failure))
            return
        }
        lastSent = "Paquet magique envoyé (102 octets) à \(destination)."
        guard let ip = device?.ip.description else {
            store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon),
                                        detail: "Paquet magique envoyé (102 octets) à \(destination) · adresse IP inconnue, pas de vérification",
                                        status: .sent))
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(mac.formatted(.upperColon))", summary: "Paquet envoyé à \(destination)", status: .info))
            return
        }
        let id = store.addWake(ToolWakeEntry(name: name, mac: mac.formatted(.upperColon),
                                             detail: "Paquet magique envoyé (102 octets) à \(destination) · vérification de \(ip) en cours",
                                             status: .pending))
        let start = Date()
        Task {
            while Date().timeIntervalSince(start) < ToolWakeModel.verifyDuration {
                if await PortScanner.isHostUp(host: ip, timeout: 1.5) {
                    let seconds = Int(Date().timeIntervalSince(start).rounded())
                    store.updateWake(id, status: .awake, detail: "Paquet envoyé à \(destination) · \(ip) répond après \(seconds)\u{00A0}s")
                    store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Réveillé après \(seconds)\u{00A0}s", status: .ok))
                    return
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            store.updateWake(id, status: .noReply, detail: "Aucune réponse de \(ip) après 60\u{00A0}s (WoL désactivé dans le BIOS\u{00A0}?)")
            store.record(ToolRecent(tool: .wol, target: "\(name) · \(ip)", summary: "Aucune réponse après 60\u{00A0}s", status: .warning))
        }
    }
}

/// Wake-on-LAN : MAC, broadcast, port, postes connus, historique des réveils.
struct WakeOnLANView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolWakeModel
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Adresse MAC") {
                    ToolTextField(placeholder: "B0:7B:25:44:A1:6C", text: $model.macText,
                                  invalid: !model.macText.isEmpty && MACAddress(model.macText) == nil)
                }
                ToolLabeledField(label: "Broadcast") {
                    ToolTextField(placeholder: "10.182.122.255", text: $model.broadcastText,
                                  invalid: !model.broadcastText.isEmpty && IPv4Address(model.broadcastText) == nil)
                }
                ToolLabeledField(label: "Port UDP") {
                    Picker("", selection: $model.port) {
                        ForEach(ToolWakeModel.PortChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(height: 34)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ToolFlowLayout(spacing: 6) {
                    Text("Postes connus\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 28)
                    ForEach(knownTargets) { device in
                        ToolChoiceChip(label: device.hostnameLabel ?? device.displayName,
                                       isSelected: device.mac.map { MACAddress(model.macText) == $0 } ?? false) {
                            model.macText = device.mac?.formatted(.upperColon) ?? ""
                        }
                    }
                    if knownTargets.isEmpty {
                        Text("aucun poste avec une adresse MAC dans l’inventaire").font(Theme.small)
                            .foregroundStyle(Theme.textTertiary).frame(height: 28)
                    }
                }
                Spacer(minLength: 0)
                Button { model.wake(state: state, store: store) } label: {
                    Label("Réveiller", systemImage: "power")
                }
                .buttonStyle(.primary)
                .fixedSize()
            }
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            (Text("Paquet magique\u{00A0}: 6 × ") + Text("FF").font(Theme.mono(12)) + Text(" + 16 × MAC = 102 octets · un test de présence (connexion TCP) est fait pendant 60\u{00A0}s après l’envoi si l’adresse IP du poste est connue."))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            history
        }
        .onAppear {
            if model.broadcastText.isEmpty {
                model.broadcastText = WakeOnLAN.defaultBroadcast(for: state.activeInterface).description
            }
            if model.macText.isEmpty, let mac = knownTargets.first?.mac { model.macText = mac.formatted(.upperColon) }
        }
    }

    /// Postes et serveurs de l'inventaire qui ont une MAC universelle.
    private var knownTargets: [Device] {
        Array(state.devices.filter { device in
            guard let mac = device.mac, !mac.isRandomized, device.ip != state.activeInterface?.address else { return false }
            return device.deviceType == .poste || device.deviceType == .serveur
        }.prefix(5))
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                ToolFieldLabel("Historique des réveils")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.panelMuted)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if store.wakeLog.isEmpty {
                Text("Aucun réveil envoyé pour l’instant.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            ForEach(store.wakeLog) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Text(ToolText.time(entry.date)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 10) {
                            Text(entry.name).font(Theme.bodySemibold).lineLimit(1)
                            Text(entry.mac).font(Theme.mono(12))
                        }
                        Text(entry.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(text: entry.status.label, tone: entry.status.tone)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}
