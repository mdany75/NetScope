import Foundation
import NetScopeCore
import SwiftUI

/// Les outils de la boîte à outils, dans l'ordre du croquis (docs/croquis/Toolbox.dc.html).
enum ToolKind: String, CaseIterable, Identifiable, Codable {
    case subnet, mac, ports, dns, whois, mtu, iperf, speedtest, wol, dhcp
    /// Occupation des étendues DHCP (note 37), juste après le Test DHCP dans la liste.
    case dhcpScopes = "dhcpscopes"
    case lldp
    /// Serveur et client TFTP (note 51).
    case tftp
    /// État des grands services en ligne (note 15).
    case cloud
    /// WAN et VPN des FortiGate (note 39) : liens WAN, SD-WAN, tunnels IPsec.
    case wan
    /// Firmware et licences du parc Fortinet (note 41) : versions, mises à jour disponibles, contrats.
    case firmware
    // Outils courriel (note 14).
    case mailSuper, mailHealth, mx, blacklist, mailRecords
    // Courriel (note 14, partie 2)
    case smtp, headers = "entetes"
    /// Capture et inspection de paquets (note 7).
    case capture
    // Vitesse des disques (note 22).
    case disques

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case adressage = "Adressage", diagnostic = "Diagnostic", performance = "Performance", services = "Services"
        case internet = "Internet"
        /// Parc Fortinet (note 41) : firmware et licences de chaque site.
        case parc = "Parc Fortinet"
        /// Entrées de la liste (note 79 : les onglets de courriel n'en font qu'une, « Courriel »).
        var tools: [ToolKind] { ToolKind.listed.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .subnet, .mac: return .adressage
        case .ports, .dns, .whois, .mtu, .capture: return .diagnostic
        case .iperf, .speedtest: return .performance
        case .disques: return .performance
        case .wol, .dhcp, .lldp, .dhcpScopes: return .services
        case .tftp: return .services
        case .cloud, .wan: return .internet
        case .firmware: return .parc
        // Note 79 : l'outil « Courriel » (sept onglets) rejoint le groupe Internet.
        case .mailSuper, .mailHealth, .mx, .blacklist, .mailRecords: return .internet
        case .smtp, .headers: return .internet
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
        case .dhcpScopes: return "Étendues DHCP"
        case .lldp: return "Capture LLDP/CDP"
        case .tftp: return "TFTP"
        case .cloud: return "État des services"
        case .wan: return "WAN et VPN"
        case .firmware: return "Firmware et licences"
        case .mailSuper: return "Super outil courriel"
        case .mailHealth: return "Santé courriel"
        case .mx: return "Recherche MX"
        case .blacklist: return "Listes noires"
        case .mailRecords: return "SPF, DKIM, DMARC…"
        case .smtp: return "Diagnostic SMTP"
        case .headers: return "Analyse d’en-têtes"
        case .capture: return "Capture de paquets"
        case .disques: return "Vitesse des disques"
        }
    }

    var summary: String {
        switch self {
        case .subnet: return "Adresse réseau, masques, broadcast, plage d’hôtes et découpage."
        case .mac: return "Formats MAC, fabricant OUI et correspondance avec l’inventaire."
        case .ports: return "Ports TCP ouverts et bannières des services texte (SSH, FTP, SMTP, HTTP)."
        case .dns: return "Résolution A, AAAA, MX, TXT, SOA, SRV, CAA, DNSSEC…\u{00A0}; comparaison de serveurs et propagation."
        case .whois: return "Propriétaire d’une adresse, d’un ASN ou d’un domaine."
        case .mtu: return "Recherche de la MTU du chemin avec le bit Don’t Fragment."
        case .iperf: return "Débit réel entre ce Mac et un serveur iperf3 du réseau."
        case .speedtest: return "Débit Internet et latence sous charge."
        case .wol: return "Envoie un paquet magique pour réveiller un poste."
        case .dhcp: return "Détecte tous les serveurs DHCP qui répondent sur le segment."
        case .dhcpScopes: return "Occupation de chaque étendue DHCP de la FortiGate\u{00A0}: baux, réservations, adresses libres et alerte avant la saturation."
        case .lldp: return "Identifie le switch, le port et le VLAN où ce Mac est branché."
        case .tftp: return "Serveur TFTP temporaire sur ce Mac et client TFTP\u{00A0}: configurations, firmwares et fichiers des téléphones IP."
        case .cloud: return "Microsoft 365, AWS, Google, GitHub…\u{00A0}: page d’état officielle et accès depuis ce réseau."
        case .wan: return "Liens WAN et SD-WAN de chaque FortiGate (état, débit, latence, perte, SLA) et tunnels VPN montés ou tombés, pour un site ou tous."
        case .firmware: return "Versions FortiOS, FortiSwitch et FortiAP de chaque site, mises à jour disponibles et contrats FortiGuard avec leur date d’expiration, en lecture seule."
        case .mailSuper: return "Domaine, adresse courriel, IP ou nom d’hôte\u{00A0}: toutes les vérifications utiles d’un coup."
        case .mailHealth: return "Note sur 100 d’un domaine (MX, SPF, DKIM, DMARC, listes noires, MTA-STS, DNSSEC) et recommandations."
        case .mx: return "Serveurs MX par priorité, leurs adresses et la cohérence du DNS inverse."
        case .blacklist: return "Une IP ou un domaine dans les principales listes noires DNSBL/RBL."
        case .mailRecords: return "Lit et explique SPF, DMARC, DKIM, BIMI, MTA-STS et TLS-RPT\u{00A0}; signale les erreurs."
        case .smtp: return "Bannière, EHLO, STARTTLS, certificat et temps de réponse d’un serveur de courriel, sans rien envoyer."
        case .headers: return "Trajet d’un courriel, SPF, DKIM, DMARC et alertes d’usurpation, à partir des en-têtes collés."
        case .capture: return "Paquets en direct ou fichier .pcap\u{00A0}: détail par couche, hexadécimal, flux, statistiques, façon Wireshark."
        case .disques: return "Écriture, lecture et accès 4\u{00A0}Kio d’un disque, d’un partage réseau ou d’un dossier nuage\u{00A0}; d’où vient la limite."
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
        case .dhcpScopes: return "chart.bar.doc.horizontal"
        case .lldp: return "cable.connector"
        case .tftp: return "arrow.up.arrow.down.square"
        case .cloud: return "cloud"
        case .wan: return "point.3.filled.connected.trianglepath.dotted"
        case .firmware: return "checkmark.seal"
        case .mailSuper: return "wand.and.stars"
        case .mailHealth: return "heart.text.square"
        case .mx: return "tray.2"
        case .blacklist: return "hand.raised"
        case .mailRecords: return "checkmark.shield"
        case .smtp: return "envelope.badge.shield.half.filled"
        case .headers: return "envelope.open"
        case .capture: return "waveform.path.ecg.rectangle"
        case .disques: return "internaldrive"
        }
    }

    /// Outils qui renvoient vers un autre écran.
    var redirect: Screen? {
        switch self {
        case .mtu: return .ping
        default: return nil
        }
    }

    static let favorites: [ToolKind] = [.subnet, .ports, .dns, .wol]

    /// Outils qui prennent toute la largeur (sans le panneau des favoris et de l'historique).
    var usesFullWidth: Bool { self == .capture || self == .dhcpScopes || self == .wan || self == .firmware || self == .tftp || self == .speedtest || self == .iperf }

    /// Recherche multiple (note 26) : `nom:dns`, `groupe:courriel` ; un mot seul lit le nom, la
    /// clé et le résumé, comme avant.
    func matches(_ query: String) -> Bool {
        SearchQuery(query, schema: .outilsListe).matches(searchItem)
    }

    var searchItem: SearchDocument {
        // L'entrée « Courriel » se retrouve par le nom, l'ancien nom et le résumé de chacun de ses onglets.
        if mailTab != nil {
            let tabs = ToolKind.mailTabs
            let names = ["Courriel", rawValue] + tabs.flatMap { [$0.label, $0.rawValue, $0.mailTab?.tabLabel ?? ""] }
            return SearchDocument(["nom": names, "groupe": [group.rawValue, "Courriel"]],
                                  freeText: names + tabs.map(\.summary))
        }
        return SearchDocument(["nom": [label, rawValue], "groupe": [group.rawValue]], freeText: [label, rawValue, summary])
    }

    // MARK: Note 79 : un seul outil « Courriel » à onglets

    /// Onglet de l'outil « Courriel » (nil pour les autres outils).
    var mailTab: MailToolTab? { MailToolTab(rawValue: rawValue) }

    /// Onglets de l'outil « Courriel », dans l'ordre affiché.
    static let mailTabs: [ToolKind] = MailToolTab.allCases.compactMap { ToolKind(rawValue: $0.rawValue) }

    /// Entrée de la liste qui porte cet outil (le Super outil porte l'entrée « Courriel »).
    var listEntry: ToolKind { mailTab != nil ? .mailSuper : self }

    /// Entrées de la liste des outils, dans l'ordre, sans doublon (`ToolRouting.listedEntries`).
    static let listed: [ToolKind] = ToolRouting.listedEntries(ToolKind.allCases.map(\.rawValue))
        .compactMap { ToolKind.resolve($0) }

    /// Outil d'un identifiant, alias et anciens liens compris (« courriel », « headers », « tftpd »).
    static func resolve(_ raw: String) -> ToolKind? { ToolKind(rawValue: ToolRouting.canonical(raw)) }

    /// Libellé de l'entrée dans la liste (« Courriel » pour les onglets de courriel).
    var listLabel: String { mailTab != nil ? "Courriel" : label }
    var listSymbol: String { mailTab != nil ? "envelope" : symbol }
    var listSummary: String {
        mailTab != nil ? "Super outil, diagnostic SMTP, analyse d’en-têtes, santé, SPF/DKIM/DMARC, MX et listes noires, en onglets." : summary
    }
}

/// Résultat récent d'un outil (panneau droit, historique de l'appareil).
struct ToolRecent: Codable, Identifiable, Hashable {
    /// Recherche de l'historique (note 26) : outil, groupe, cible, état, résumé.
    var searchItem: SearchDocument {
        SearchDocument(["nom": [tool.label, tool.rawValue], "groupe": [tool.group.rawValue], "cible": [target],
                        "etat": [status.label]],
                       freeText: [tool.label, target, summary, status.label])
    }

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

    @Published var selectedTool: ToolKind = .subnet {
        didSet { if selectedTool.mailTab != nil { lastMailTool = selectedTool } }
    }
    /// Note 79 : dernier onglet ouvert de l'outil « Courriel » (son entrée dans la liste y ramène).
    private(set) var lastMailTool: ToolKind = .mailSuper
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
    let smtp = ToolSMTPModel()
    let headers = ToolHeaderModel()
    /// Capture de paquets (note 7).
    let capture = ToolPacketCaptureModel()

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
        if isEphemeral, let raw = ProcessInfo.processInfo.environment["NETSCOPE_OUTIL_DEMO"], let tool = ToolKind.resolve(raw) {
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
            AppLog.shared.error("Outils", "Enregistrement impossible de \(url.path)\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Outils courriel en démonstration : domaine exemple.ca (réponses DNS fixes).
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
