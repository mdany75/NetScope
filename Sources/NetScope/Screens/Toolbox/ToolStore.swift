import Foundation
import NetScopeCore
import SwiftUI

/// Les outils de la boîte à outils, dans l'ordre du croquis (docs/croquis/Toolbox.dc.html).
enum ToolKind: String, CaseIterable, Identifiable, Codable {
    case subnet, mac, ports, dns, whois, mtu, iperf, speedtest, wol, dhcp, lldp
    // Outils courriel (note 14).
    case mailSuper, mailHealth, mx, blacklist, mailRecords

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case adressage = "Adressage", diagnostic = "Diagnostic", performance = "Performance", services = "Services"
        case courriel = "Courriel"
        var tools: [ToolKind] { ToolKind.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .subnet, .mac: return .adressage
        case .ports, .dns, .whois, .mtu: return .diagnostic
        case .iperf, .speedtest: return .performance
        case .wol, .dhcp, .lldp: return .services
        case .mailSuper, .mailHealth, .mx, .blacklist, .mailRecords: return .courriel
        }
    }

    var label: String {
        switch self {
        case .subnet: return "Calculateur de sous-réseau"
        case .mac: return "Convertisseur MAC/OUI"
        case .ports: return "Scan de ports"
        case .dns: return "DNS"
        case .whois: return "Whois"
        case .mtu: return "Test MTU"
        case .iperf: return "iperf3"
        case .speedtest: return "Speedtest"
        case .wol: return "Wake-on-LAN"
        case .dhcp: return "Test DHCP"
        case .lldp: return "Capture LLDP/CDP"
        case .mailSuper: return "Super outil courriel"
        case .mailHealth: return "Santé courriel"
        case .mx: return "Recherche MX"
        case .blacklist: return "Listes noires"
        case .mailRecords: return "SPF, DKIM, DMARC…"
        }
    }

    var summary: String {
        switch self {
        case .subnet: return "Adresse réseau, masques, broadcast, plage d’hôtes et découpage."
        case .mac: return "Formats MAC, fabricant OUI et correspondance avec l’inventaire."
        case .ports: return "Ports TCP ouverts et bannières des services texte (SSH, FTP, SMTP, HTTP)."
        case .dns: return "Résolution A, AAAA, MX, PTR, TXT, NS et CNAME sur le serveur choisi."
        case .whois: return "Propriétaire d’une adresse, d’un ASN ou d’un domaine."
        case .mtu: return "Recherche de la MTU du chemin avec le bit Don’t Fragment."
        case .iperf: return "Débit réel entre ce Mac et un serveur iperf3 du réseau."
        case .speedtest: return "Débit Internet et latence sous charge."
        case .wol: return "Envoie un paquet magique pour réveiller un poste."
        case .dhcp: return "Détecte tous les serveurs DHCP qui répondent sur le segment."
        case .lldp: return "Identifie le switch, le port et le VLAN où ce Mac est branché."
        case .mailSuper: return "Domaine, adresse courriel, IP ou nom d’hôte\u{00A0}: toutes les vérifications utiles d’un coup."
        case .mailHealth: return "Note sur 100 d’un domaine (MX, SPF, DKIM, DMARC, listes noires, MTA-STS, DNSSEC) et recommandations."
        case .mx: return "Serveurs MX par priorité, leurs adresses et la cohérence du DNS inverse."
        case .blacklist: return "Une IP ou un domaine dans les principales listes noires DNSBL/RBL."
        case .mailRecords: return "Lit et explique SPF, DMARC, DKIM, BIMI, MTA-STS et TLS-RPT\u{00A0}; signale les erreurs."
        }
    }

    var symbol: String {
        switch self {
        case .subnet: return "function"
        case .mac: return "tag"
        case .ports: return "door.left.hand.open"
        case .dns: return "globe"
        case .whois: return "person.text.rectangle"
        case .mtu: return "ruler"
        case .iperf: return "speedometer"
        case .speedtest: return "bolt"
        case .wol: return "power"
        case .dhcp: return "shield.lefthalf.filled"
        case .lldp: return "cable.connector"
        case .mailSuper: return "wand.and.stars"
        case .mailHealth: return "heart.text.square"
        case .mx: return "tray.2"
        case .blacklist: return "hand.raised"
        case .mailRecords: return "checkmark.shield"
        }
    }

    /// Outils qui renvoient vers un autre écran.
    var redirect: Screen? {
        switch self {
        case .mtu: return .ping
        case .iperf, .speedtest: return .speedtest
        default: return nil
        }
    }

    static let favorites: [ToolKind] = [.subnet, .ports, .dns, .wol]

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [label, rawValue, summary].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Résultat récent d'un outil (panneau droit, historique de l'appareil).
struct ToolRecent: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case ok, warning, failure, info
        var tone: Tone {
            switch self {
            case .ok: return .success
            case .warning: return .warning
            case .failure: return .critical
            case .info: return .accent
            }
        }
        var label: String {
            switch self {
            case .ok: return "OK"
            case .warning: return "Alerte"
            case .failure: return "Échec"
            case .info: return "Info"
            }
        }
    }

    var id = UUID()
    var tool: ToolKind
    var target: String
    var summary: String
    var date = Date()
    var status: Status
    /// Titre affiché à la place du nom de l'outil (« Sonde web »).
    var title: String? = nil

    var displayTitle: String { title ?? tool.label }
}

/// Une entrée de l'historique des réveils.
struct ToolWakeEntry: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case pending, awake, noReply, sent, failed
        var label: String {
            switch self {
            case .pending: return "En attente"
            case .awake: return "Réveillé"
            case .noReply: return "Sans réponse"
            case .sent: return "Envoyé"
            case .failed: return "Échec"
            }
        }
        var tone: Tone {
            switch self {
            case .pending: return .accent
            case .awake: return .success
            case .noReply: return .warning
            case .sent: return .neutral
            case .failed: return .critical
            }
        }
    }

    var id = UUID()
    var date = Date()
    var name: String
    var mac: String
    var detail: String
    var status: Status
}

/// État de la boîte à outils, conservé quand on change d'écran (les vues sont recréées).
/// Historique des commandes, résultats récents et réveils : enregistrés dans
/// ~/Library/Application Support/NetScope/outils.json (en mémoire seulement en démonstration).
@MainActor
final class ToolStore: ObservableObject {
    static let shared = ToolStore()

    @Published var selectedTool: ToolKind = .subnet
    @Published var toolFilter = ""
    @Published private(set) var commands: [String] = []
    @Published private(set) var recents: [ToolRecent] = []
    @Published private(set) var wakeLog: [ToolWakeEntry] = []

    let subnet = ToolSubnetModel()
    let mac = ToolMACModel()
    let ports = ToolPortScanModel()
    let dns = ToolDNSModel()
    let whois = ToolWhoisModel()
    let wol = ToolWakeModel()
    let dhcp = ToolDHCPModel()
    let neighbors = ToolNeighborModel()
    // Outils courriel (note 14).
    let mailSuper = ToolMailSuperModel()
    let mailHealth = ToolMailHealthModel()
    let mx = ToolMXModel()
    let blacklist = ToolBlacklistModel()
    let mailRecords = ToolMailRecordsModel()

    /// Démonstration (--demo) : données des croquis.
    let isDemo: Bool
    /// Démonstration ou capture (--snapshot) : rien n'est lu ni écrit sur le disque.
    let isEphemeral: Bool
    private let url: URL

    private struct Snapshot: Codable {
        var commands: [String]
        var recents: [ToolRecent]
        var wakeLog: [ToolWakeEntry]
    }

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("outils.json")
        // Captures de développement (--snapshot, --demo) : NETSCOPE_OUTIL_DEMO=dhcp (ou lldp…) ouvre cet outil.
        if isEphemeral, let raw = ProcessInfo.processInfo.environment["NETSCOPE_OUTIL_DEMO"], let tool = ToolKind(rawValue: raw) {
            selectedTool = tool
        }
        if isDemo {
            loadDemo()
            loadMailDemo()
        } else if !isEphemeral, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            commands = saved.commands
            recents = saved.recents
            wakeLog = saved.wakeLog
        }
    }

    // MARK: Historique

    func record(command: String) {
        commands.removeAll { $0 == command }
        commands.insert(command, at: 0)
        if commands.count > 40 { commands.removeLast(commands.count - 40) }
        save()
    }

    func record(_ recent: ToolRecent) {
        recents.insert(recent, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        save()
    }

    @discardableResult
    func addWake(_ entry: ToolWakeEntry) -> UUID {
        wakeLog.insert(entry, at: 0)
        if wakeLog.count > 30 { wakeLog.removeLast(wakeLog.count - 30) }
        save()
        return entry.id
    }

    func updateWake(_ id: UUID, status: ToolWakeEntry.Status, detail: String) {
        guard let index = wakeLog.firstIndex(where: { $0.id == id }) else { return }
        wakeLog[index].status = status
        wakeLog[index].detail = detail
        save()
    }

    func clearCommands() {
        commands = []
        save()
    }

    /// Résultats concernant une cible (IP, MAC ou nom), pour la fiche de l'appareil.
    func recents(matching keys: [String]) -> [ToolRecent] {
        let lowered = keys.map { $0.lowercased() }.filter { !$0.isEmpty }
        return recents.filter { recent in lowered.contains { recent.target.lowercased().contains($0) } }
    }

    // MARK: Navigation

    /// Ouvre un outil (depuis la fiche d'un appareil, par exemple).
    func open(_ tool: ToolKind, in state: AppState) {
        selectedTool = tool
        toolFilter = ""
        state.open(.outils)
    }

    // MARK: Persistance

    private func save() {
        guard !isEphemeral else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Snapshot(commands: commands, recents: recents, wakeLog: wakeLog)).write(to: url, options: .atomic)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
    }

    /// Outils courriel en démonstration : domaine fictif groupecouture.ca (réponses DNS fixes).
    private func loadMailDemo() {
        mailSuper.startDemo()
        mailHealth.startDemo()
        mx.startDemo()
        blacklist.startDemo()
        mailRecords.startDemo()
    }

    /// Données des croquis (renderVals de Toolbox.dc.html).
    private func loadDemo() {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        commands = [
            "dhcp-probe -i en0 -t 5", "lldp-listen -i en7",
            "scan -sV -p 1-1024,9100 10.182.122.111", "dig -x 10.182.122.111 @10.182.122.1",
            "ipcalc 192.168.50.0/24 --split 26", "whois 8.8.8.8", "wol B0:7B:25:44:9F:20 -b 10.182.122.255 -p 9",
        ]
        recents = [
            ToolRecent(tool: .dhcp, target: "en0 · 10.182.122.0/24", summary: "2 serveurs · 1 non autorisé (10.182.122.250)",
                       date: ago(4), status: .warning),
            ToolRecent(tool: .lldp, target: "en7", summary: "SW-ETG2-01 · port 1/22 · VLAN 1", date: ago(9), status: .ok),
            ToolRecent(tool: .ports, target: "10.182.122.111", summary: "4 ouverts\u{00A0}: 80, 443, 631, 9100", date: ago(22), status: .ok),
            ToolRecent(tool: .dns, target: "10.182.122.111", summary: "PTR BRN94DDF818157D.bureau.local.", date: ago(31), status: .ok),
            ToolRecent(tool: .whois, target: "8.8.8.8", summary: "Google LLC · AS15169 · 8.8.8.0/24", date: ago(48), status: .ok),
            ToolRecent(tool: .wol, target: "WKS341 · B0:7B:25:44:9F:20", summary: "Aucune réponse après 60 s", date: ago(60 * 15), status: .warning),
        ]
        wakeLog = [
            ToolWakeEntry(date: ago(35), name: "WKS346", mac: "B0:7B:25:44:A1:6C",
                          detail: "Paquet envoyé à 10.182.122.255:9 · répond après 18 s", status: .awake),
            ToolWakeEntry(date: ago(60 * 15), name: "WKS341", mac: "B0:7B:25:44:9F:20",
                          detail: "Aucune réponse après 60 s (WoL désactivé dans le BIOS\u{00A0}?)", status: .noReply),
        ]
    }
}

// MARK: - Mise en forme commune

enum ToolText {
    /// « 09:42:07 », « hier 17:02 », « 2026-10-14 10:20 ».
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return "hier " + formatter.string(from: date)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// « Auj. 09:42 », « Hier 14:07 », « 2026-10-14 10:20 » (chronologie).
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) { return "Auj. " + formatter.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Hier " + formatter.string(from: date)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// « à l’instant », « il y a 4 min », « il y a 15 h », puis « hier 17:02 » au-delà de 24 h.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "à l’instant" }
        if seconds < 3600 { return "il y a \(Int((seconds / 60).rounded()))\u{00A0}min" }
        if seconds < 24 * 3600 { return "il y a \(Int(seconds / 3600))\u{00A0}h" }
        return time(date, now: now)
    }
}
