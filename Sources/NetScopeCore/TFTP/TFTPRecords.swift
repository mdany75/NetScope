import Foundation

/// Un transfert du journal TFTP (serveur ou client), enregistré par site.
public struct TFTPTransferRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        /// Le Mac sert le fichier (un appareil l'a demandé).
        case server
        /// Le Mac a lancé le transfert (client).
        case client

        public var label: String { self == .server ? "Serveur" : "Client" }
    }

    /// Sens, vu du Mac.
    public enum Flow: String, Codable, Sendable {
        /// Le Mac envoie le fichier à l'appareil (RRQ reçu par le serveur, put du client).
        case toDevice
        /// Le Mac reçoit le fichier de l'appareil (WRQ reçu par le serveur, get du client).
        case fromDevice

        public var label: String { self == .toDevice ? "Envoi" : "Réception" }
        public var symbol: String { self == .toDevice ? "arrow.up.right" : "arrow.down.left" }
    }

    public enum Status: String, Codable, Sendable {
        case running, done, failed, refused, cancelled

        public var label: String {
            switch self {
            case .running: return "En cours"
            case .done: return "Réussi"
            case .failed: return "Échec"
            case .refused: return "Refusé"
            case .cancelled: return "Annulé"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var role: Role
    public var flow: Flow
    /// Adresse IP de l'appareil.
    public var peer: String
    /// Nom de l'appareil (scan), s'il est connu.
    public var peerName: String?
    public var filename: String
    public var bytes: Int64
    /// Taille totale attendue (fichier lu ou tsize annoncé).
    public var total: Int64?
    public var seconds: TimeInterval
    public var status: Status
    /// Détail en clair (erreur, options négociées).
    public var detail: String
    /// Site actif au moment du transfert (clé de SiteFiles), pour l'historique par site.
    public var site: String?
    public var blockSize: Int?
    public var windowSize: Int?
    /// Raison courte d'un échec ou d'un refus (« Fichier introuvable », « Délai dépassé »).
    public var reason: String?

    public init(id: UUID = UUID(), date: Date = Date(), role: Role, flow: Flow, peer: String, peerName: String? = nil,
                filename: String, bytes: Int64 = 0, total: Int64? = nil, seconds: TimeInterval = 0, status: Status = .running,
                detail: String = "", site: String? = nil, blockSize: Int? = nil, windowSize: Int? = nil,
                reason: String? = nil) {
        self.id = id
        self.date = date
        self.role = role
        self.flow = flow
        self.peer = peer
        self.peerName = peerName
        self.filename = filename
        self.bytes = bytes
        self.total = total
        self.seconds = seconds
        self.status = status
        self.detail = detail
        self.site = site
        self.blockSize = blockSize
        self.windowSize = windowSize
        self.reason = reason
    }

    /// État affiché : la raison d'un échec ou d'un refus, sinon l'état.
    public var statusText: String {
        switch status {
        case .failed, .refused: return reason ?? status.label
        default: return status.label
        }
    }

    /// Avancement de 0 à 1, si la taille est connue.
    public var fraction: Double? {
        if status == .done { return 1 }
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    /// « 1,2 Mio/s ».
    public var rateText: String { TFTPFormat.rate(bytes: bytes, seconds: seconds) }

    /// « 18,4 Mio » ou « 4,1 Mio sur 18,4 Mio ».
    public var sizeText: String {
        if status == .running, let total, total > 0 { return "\(TFTPFormat.bytes(bytes)) sur \(TFTPFormat.bytes(total))" }
        if bytes == 0, let total, status != .done { return TFTPFormat.bytes(total) }
        return TFTPFormat.bytes(bytes)
    }
}

/// Historique des transferts : le plus récent d'abord, borné, filtré par site.
public enum TFTPHistory {
    public static let limit = 300

    /// Ajoute ou remplace (même identifiant) un transfert.
    public static func upsert(_ record: TFTPTransferRecord, into list: [TFTPTransferRecord]) -> [TFTPTransferRecord] {
        var result = list
        if let index = result.firstIndex(where: { $0.id == record.id }) {
            result[index] = record
        } else {
            result.insert(record, at: 0)
        }
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// Transferts d'un site (nil : ceux sans site, avant le premier site).
    public static func forSite(_ site: String?, in list: [TFTPTransferRecord]) -> [TFTPTransferRecord] {
        list.filter { $0.site == site }
    }

    /// Transferts restés « en cours » à la relecture (application quittée pendant un transfert).
    public static func closingInterrupted(_ list: [TFTPTransferRecord]) -> [TFTPTransferRecord] {
        list.map { record in
            guard record.status == .running else { return record }
            var copy = record
            copy.status = .cancelled
            copy.detail = "Interrompu (NetScope a été quitté pendant le transfert)."
            return copy
        }
    }
}

/// Arrêt automatique du serveur : après `delay` secondes sans transfert (aucun en cours).
public enum TFTPAutoStop {
    /// Secondes restantes avant l'arrêt, nil si jamais (délai nul) ; 0 : arrêter maintenant.
    public static func remaining(lastActivity: Date, delay: TimeInterval?, activeTransfers: Int, now: Date = Date()) -> TimeInterval? {
        guard let delay, delay > 0 else { return nil }
        guard activeTransfers == 0 else { return delay }
        return max(0, delay - now.timeIntervalSince(lastActivity))
    }

    /// « 14 min 05 s », « 42 s ».
    public static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 3600 { return "\(total / 3600)\u{00A0}h\u{00A0}\(String(format: "%02d", (total % 3600) / 60))\u{00A0}min" }
        if total >= 60 { return "\(total / 60)\u{00A0}min\u{00A0}\(String(format: "%02d", total % 60))\u{00A0}s" }
        return "\(total)\u{00A0}s"
    }
}

/// État du coupe-feu de macOS (Réglages Système › Réseau › Coupe-feu), lu par socketfilterfw.
public struct TFTPFirewallStatus: Equatable, Sendable {
    public enum AppState: Equatable, Sendable { case allowed, blocked, unknown }

    public var enabled: Bool
    /// « Bloquer toutes les connexions entrantes ».
    public var blockAll: Bool
    public var app: AppState

    public init(enabled: Bool, blockAll: Bool, app: AppState) {
        self.enabled = enabled
        self.blockAll = blockAll
        self.app = app
    }

    /// Lit les sorties de `socketfilterfw --getglobalstate`, `--getblockall` et `--getappblocked <app>`.
    public static func parse(globalState: String, blockAll: String, app: String) -> TFTPFirewallStatus {
        let global = globalState.lowercased()
        // « Firewall is enabled. (State = 1) » ; état 2 : services essentiels seulement.
        let enabled = global.contains("enabled") || global.contains("state = 1") || global.contains("state = 2")
        let blocking = blockAll.lowercased().contains("enabled") || global.contains("state = 2")
        let appText = app.lowercased()
        let appState: AppState = appText.contains("is permitted") ? .allowed : (appText.contains("is blocked") ? .blocked : .unknown)
        return TFTPFirewallStatus(enabled: enabled && !global.contains("disabled"), blockAll: blocking, app: appState)
    }

    /// Avertissement à montrer, ou nil si le coupe-feu ne gêne pas.
    public var warning: String? {
        guard enabled else { return nil }
        if blockAll {
            return "Le coupe-feu de macOS bloque toutes les connexions entrantes\u{00A0}: les appareils ne joindront pas le serveur TFTP. Désactivez «\u{00A0}Bloquer toutes les connexions entrantes\u{00A0}» dans Réglages Système › Réseau › Coupe-feu le temps du transfert."
        }
        switch app {
        case .blocked:
            return "Le coupe-feu de macOS bloque les connexions entrantes vers NetScope\u{00A0}: autorisez NetScope dans Réglages Système › Réseau › Coupe-feu › Options."
        case .unknown:
            return "Le coupe-feu de macOS est actif\u{00A0}: au premier démarrage, macOS demandera d’accepter les connexions entrantes pour NetScope. Répondez «\u{00A0}Autoriser\u{00A0}»."
        case .allowed:
            return nil
        }
    }

    /// Lit l'état du coupe-feu (commande locale, aucun trafic réseau).
    public static func read(appPath: String) async -> TFTPFirewallStatus? {
        let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard let global = try? await ToolProcess.run(tool, ["--getglobalstate"], timeout: 5) else { return nil }
        let blockAll = (try? await ToolProcess.run(tool, ["--getblockall"], timeout: 5)) ?? ""
        let app = (try? await ToolProcess.run(tool, ["--getappblocked", appPath], timeout: 5)) ?? ""
        return parse(globalState: global, blockAll: blockAll, app: app)
    }
}
