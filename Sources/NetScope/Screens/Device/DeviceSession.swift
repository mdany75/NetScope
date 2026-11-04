import Foundation
import NetScopeCore
import SwiftUI

/// Onglets de la fiche appareil (croquis docs/croquis/Device.dc.html).
enum DeviceTab: String, CaseIterable, Identifiable {
    case apercu, ports, web, ressources, historique, notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apercu: return "Aperçu"
        case .ports: return "Ports et services"
        case .web: return "Web"
        case .ressources: return "Ressources"
        case .historique: return "Historique"
        case .notes: return "Notes"
        }
    }
}

/// Sonde web d'un appareil (onglet Web).
@MainActor
final class DeviceWebModel: ObservableObject {
    @Published var urlText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var result: HTTPProbeResult?
    @Published private(set) var probedAt: Date?
    @Published var error: String?

    func run(store: ToolStore) {
        let text = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            error = "Adresse web invalide (exemple\u{00A0}: https://10.182.122.111/)."
            return
        }
        error = nil
        isRunning = true
        store.record(command: "curl -skI '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")
        Task {
            do {
                let result = try await HTTPProbe.probe(url)
                self.result = result
                self.probedAt = Date()
                let summary = [result.statusText, result.title, result.server].compactMap { $0 }.joined(separator: " · ")
                let warning = result.certificate.map { !$0.isTrusted } ?? false
                store.record(ToolRecent(tool: .ports, target: url.host ?? text, summary: summary,
                                        status: warning ? .warning : .ok, title: "Sonde web"))
            } catch {
                self.result = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isRunning = false
        }
    }
}

/// État des fiches appareil conservé entre deux visites : onglet, scans et sondes par appareil.
@MainActor
final class DeviceSession: ObservableObject {
    static let shared = DeviceSession()

    @Published var tab: DeviceTab = DeviceSession.initialTab

    /// Captures de développement (--snapshot) : NETSCOPE_DEVICE_TAB=ports (ou web, historique,
    /// notes) ouvre la fiche sur cet onglet, à l'image de NETSCOPE_OUTIL_DEMO.
    private static var initialTab: DeviceTab {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_DEVICE_TAB"],
              let tab = DeviceTab(rawValue: raw) else { return .apercu }
        return tab
    }
    private var portModels: [Device.ID: ToolPortScanModel] = [:]
    private var webModels: [Device.ID: DeviceWebModel] = [:]

    func portModel(for device: Device) -> ToolPortScanModel {
        if let model = portModels[device.id] { return model }
        let model = ToolPortScanModel(target: device.ip.description)
        portModels[device.id] = model
        return model
    }

    func webModel(for device: Device) -> DeviceWebModel {
        if let model = webModels[device.id] { return model }
        let model = DeviceWebModel()
        model.urlText = DeviceSession.defaultURL(for: device)
        webModels[device.id] = model
        return model
    }

    /// Adresses web candidates d'après les ports ouverts connus.
    static func webURLs(for device: Device) -> [String] {
        let host = device.ip.description
        var urls = device.openPorts.compactMap { port -> String? in
            guard let scheme = PortScanner.webScheme(for: port) else { return nil }
            let standard = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            return "\(scheme)://\(host)" + (standard ? "" : ":\(port)") + "/"
        }
        if urls.isEmpty { urls = ["http://\(host)/", "https://\(host)/"] }
        return urls.sorted { ($0.hasPrefix("https") ? 0 : 1, $0) < ($1.hasPrefix("https") ? 0 : 1, $1) }
    }

    static func defaultURL(for device: Device) -> String {
        webURLs(for: device).first ?? "http://\(device.ip)/"
    }
}

/// Notes du technicien par appareil, enregistrées dans
/// ~/Library/Application Support/NetScope/notes-appareils.json (clé : MAC, sinon IP).
@MainActor
final class DeviceNotesStore: ObservableObject {
    static let shared = DeviceNotesStore()

    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var savedAt: [String: Date] = [:]
    private let url: URL
    private let isEphemeral: Bool

    private init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("notes-appareils.json")
        if arguments.contains("--demo") {
            notes["94:dd:f8:18:15:7d"] = """
            2026-10-14 — Toner BK remplacé (TN-2620). Prochain prévu vers janvier.
            2026-09-02 — Déplacée du 1er étage vers l’accueil (2e). Nouveau câble vers SW-ETG2-01 port 1/14, VLAN 30.
            Réservation DHCP créée sur le FortiGate-60F pour 94:DD:F8:18:15:7D.
            À faire : passer SNMP en v3 et désactiver la communauté public.
            """
        } else if !isEphemeral, let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            notes = saved
        }
    }

    static func key(for device: Device) -> String {
        device.mac?.description ?? device.id
    }

    func note(for device: Device) -> String {
        notes[DeviceNotesStore.key(for: device)] ?? ""
    }

    func setNote(_ text: String, for device: Device) {
        let key = DeviceNotesStore.key(for: device)
        notes[key] = text.isEmpty ? nil : text
        savedAt[key] = Date()
        save()
    }

    private func save() {
        guard !isEphemeral else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(notes).write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
    }
}

extension DeviceType {
    /// Symbole SF Symbols de la famille d'appareil.
    var toolSymbol: String {
        switch self {
        case .poste: return "desktopcomputer"
        case .serveur: return "server.rack"
        case .imprimante: return "printer"
        case .camera: return "video"
        case .pointAcces: return "wifi"
        case .switch: return "rectangle.connected.to.line.below"
        case .routeur: return "shield.lefthalf.filled"
        case .telephone: return "iphone"
        case .console: return "gamecontroller"
        case .domotique: return "house"
        case .iot: return "sensor"
        case .inconnu: return "questionmark.circle"
        }
    }
}
