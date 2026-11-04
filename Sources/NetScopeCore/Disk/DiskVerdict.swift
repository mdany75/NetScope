import Foundation

// Bilan en clair d'un test de vitesse : d'où vient la limite ? Disque local : sa classe probable.
// Partage réseau : on compare le débit obtenu au débit du lien (Ethernet ou Wi-Fi) et à la latence
// vers le serveur, pour dire si la limite vient du réseau, de la latence ou du serveur. Dossier
// nuage : vitesse de la copie locale, puis temps jusqu'à « envoyé » comparé au débit montant connu.

/// Origine probable de la limite.
public enum DiskLimit: String, Codable, Sendable {
    case disque, reseau, latence, serveur, internet, service, inconnu

    public var label: String {
        switch self {
        case .disque: return "Disque"
        case .reseau: return "Réseau"
        case .latence: return "Latence"
        case .serveur: return "Serveur"
        case .internet: return "Lien Internet"
        case .service: return "Service nuage"
        case .inconnu: return "Indéterminé"
        }
    }
}

/// Contexte réseau d'un partage, mesuré à côté du test.
public struct DiskNetworkContext: Codable, Hashable, Sendable {
    /// Débit du lien actif (Mbit/s) : débit PHY du Wi-Fi ou vitesse négociée de l'Ethernet.
    public var linkMbps: Double?
    /// « Wi-Fi », « Ethernet ».
    public var linkKind: String?
    public var interfaceName: String?
    /// Latence moyenne vers le serveur (ping), nil si le serveur ne répond pas au ping.
    public var serverLatencyMs: Double?
    /// Débit montant Internet du dernier Speedtest (Mbit/s), pour les dossiers nuage.
    public var internetUpMbps: Double?

    public init(linkMbps: Double? = nil, linkKind: String? = nil, interfaceName: String? = nil,
                serverLatencyMs: Double? = nil, internetUpMbps: Double? = nil) {
        self.linkMbps = linkMbps
        self.linkKind = linkKind
        self.interfaceName = interfaceName
        self.serverLatencyMs = serverLatencyMs
        self.internetUpMbps = internetUpMbps
    }

    public var isWifi: Bool { linkKind?.lowercased().contains("wi-fi") == true || linkKind?.lowercased().contains("wifi") == true }
}

/// Bilan affiché sous les mesures.
public struct DiskVerdict: Codable, Hashable, Sendable {
    public enum Tone: String, Codable, Sendable { case success, accent, warning, critical, neutral }

    public var limit: DiskLimit
    public var title: String
    public var detail: String
    public var tone: Tone

    public init(limit: DiskLimit, title: String, detail: String, tone: Tone) {
        self.limit = limit
        self.title = title
        self.detail = detail
        self.tone = tone
    }
}

public enum DiskAdvisor {
    /// Part utile d'un lien après les en-têtes TCP/IP et SMB : au-delà de 70 % du débit nominal
    /// du lien, c'est le lien qui limite (un Wi-Fi rend rarement plus de 60 à 70 % de son débit PHY).
    public static let linkSaturation = 0.7
    /// Latence vers le serveur au-delà de laquelle un partage SMB/NFS ralentit nettement
    /// (partage distant, VPN) : chaque requête attend l'aller-retour.
    public static let highLatencyMs = 15.0
    /// Débit montant au-delà duquel l'envoi vers le nuage est jugé limité par Internet.
    public static let uploadSaturation = 0.7

    public static func verdict(kind: DiskLocationKind, result: DiskBenchmarkResult, context: DiskNetworkContext = DiskNetworkContext()) -> DiskVerdict {
        switch kind {
        case .interne, .externe: return local(kind: kind, result: result)
        case .reseau: return network(result: result, context: context)
        case .nuage: return cloud(result: result, context: context)
        }
    }

    static func local(kind: DiskLocationKind, result: DiskBenchmarkResult) -> DiskVerdict {
        guard let write = result.writeMBps, let read = result.readMBps else {
            return DiskVerdict(limit: .inconnu, title: "Mesure incomplète", detail: "Relancez le test pour obtenir un bilan.", tone: .neutral)
        }
        let kindText = kind == .interne ? "Disque interne" : "Disque externe"
        let drive = DiskMath.driveClass(readMBps: read)
        var detail = "Écriture \(DiskFormat.rateWithUnit(write)), lecture \(DiskFormat.rateWithUnit(read))\u{00A0}: profil \(drive)."
        if kind == .externe, read < 450, read >= 300 {
            detail += " Plafond typique de l’USB 3.0 (5 Gbit/s) ou d’un SSD SATA\u{00A0}: un câble ou un port plus rapide peut aider."
        } else if kind == .externe, read < 45 {
            detail += " Débit d’un port USB 2.0\u{00A0}: vérifiez le câble, le concentrateur et le port."
        }
        if write < read * 0.4 {
            detail += " L’écriture est bien plus lente que la lecture (cache plein, disque presque plein ou mémoire QLC)."
        }
        let tone: DiskVerdict.Tone = read >= 300 ? .success : (read >= 80 ? .accent : .warning)
        return DiskVerdict(limit: .disque, title: "\(kindText)\u{00A0}: limité par le disque lui-même", detail: detail, tone: tone)
    }

    static func network(result: DiskBenchmarkResult, context: DiskNetworkContext) -> DiskVerdict {
        guard let write = result.writeMBps, let read = result.readMBps else {
            return DiskVerdict(limit: .inconnu, title: "Mesure incomplète", detail: "Relancez le test pour obtenir un bilan.", tone: .neutral)
        }
        let best = DiskMath.megabits(fromMegabytes: max(write, read))
        let measured = "Meilleur débit\u{00A0}: \(DiskFormat.bits(best)) (\(DiskFormat.rateWithUnit(max(write, read))))."
        let linkName = context.isWifi ? "réseau Wi-Fi" : (context.linkKind.map { "lien \($0)" } ?? "lien réseau")
        if let link = context.linkMbps, link > 0, best >= link * linkSaturation {
            var detail = measured + " C’est \(Int((best / link * 100).rounded()))\u{00A0}% du débit du \(linkName) (\(DiskFormat.bits(link)))\u{00A0}: le serveur et ses disques suivent."
            detail += context.isWifi ? " Branchez ce Mac en Ethernet pour aller plus vite." : " Un lien plus rapide (2,5 ou 10 Gbit/s) serait nécessaire pour aller plus loin."
            return DiskVerdict(limit: .reseau, title: "Limité par le \(linkName) à \(DiskFormat.bits(link))", detail: detail, tone: .warning)
        }
        if let latency = context.serverLatencyMs, latency >= highLatencyMs {
            let detail = measured + " La latence vers le serveur est de \(DiskFormat.latency(latency))\u{00A0}: partage distant, VPN ou Wi-Fi encombré. Chaque requête attend l’aller-retour."
            return DiskVerdict(limit: .latence, title: "Limité par la latence vers le serveur (\(DiskFormat.latency(latency)))", detail: detail, tone: .warning)
        }
        if let link = context.linkMbps, link > 0 {
            var detail = measured + " Le \(linkName) permettrait environ \(DiskFormat.bits(link * linkSaturation)) utiles"
            if let latency = context.serverLatencyMs { detail += " et la latence est faible (\(DiskFormat.latency(latency)))" }
            detail += "\u{00A0}: la limite vient du serveur (disques, processeur, chiffrement SMB) ou de sa propre connexion."
            return DiskVerdict(limit: .serveur, title: "Limité par le serveur, pas par le réseau", detail: detail, tone: .accent)
        }
        return DiskVerdict(limit: .inconnu, title: "Débit du lien inconnu",
                           detail: measured + " Le débit du lien actif n’a pas pu être lu\u{00A0}: impossible de dire si le réseau ou le serveur limite.",
                           tone: .neutral)
    }

    static func cloud(result: DiskBenchmarkResult, context: DiskNetworkContext) -> DiskVerdict {
        let local = result.writeMBps.map { "Copie locale écrite à \(DiskFormat.rateWithUnit($0))." } ?? ""
        switch result.cloudStatus {
        case .envoye:
            if let seconds = result.uploadSeconds, seconds < DiskCloudTracker.minimumUploadSeconds {
                return DiskVerdict(limit: .inconnu, title: "Envoyé pendant l’écriture",
                                   detail: local + " Le fichier était déjà envoyé à la fin de l’écriture\u{00A0}: débit d’envoi non mesurable. Choisissez un fichier plus gros pour le mesurer.",
                                   tone: .success)
            }
            guard let up = result.uploadMbps, let seconds = result.uploadSeconds else { break }
            var detail = local + " Envoyé \(DiskFormat.duration(seconds)) après la fin de l’écriture, soit au moins \(DiskFormat.bits(up))."
            if let internet = context.internetUpMbps, internet > 0 {
                if up >= internet * uploadSaturation {
                    detail += " C’est \(Int((up / internet * 100).rounded()))\u{00A0}% du débit montant mesuré par le Speedtest (\(DiskFormat.bits(internet)))."
                    return DiskVerdict(limit: .internet, title: "Envoi limité par le lien Internet montant", detail: detail, tone: .accent)
                }
                detail += " Le Speedtest a mesuré \(DiskFormat.bits(internet)) en montée\u{00A0}: le service nuage ralentit l’envoi (file d’attente, limite du service ou petit fichier)."
                return DiskVerdict(limit: .service, title: "Envoi limité par le service nuage", detail: detail, tone: .warning)
            }
            detail += " Lancez un Speedtest pour comparer au débit montant d’Internet."
            return DiskVerdict(limit: .inconnu, title: "Envoyé en \(DiskFormat.duration(seconds))", detail: detail, tone: .success)
        case .nonFourni:
            return DiskVerdict(limit: .inconnu, title: "Ce service ne fournit pas l’état d’envoi",
                               detail: local + " Le dossier ne renseigne pas les attributs de synchronisation du fichier\u{00A0}: seule l’écriture locale est mesurée. Suivez l’envoi dans l’app du service.",
                               tone: .neutral)
        case .delaiDepasse:
            return DiskVerdict(limit: .service, title: "Envoi non terminé dans le délai",
                               detail: local + " Le service n’a pas signalé «\u{00A0}envoyé\u{00A0}» à temps\u{00A0}: envoi en pause, file d’attente chargée ou lien montant lent.",
                               tone: .warning)
        case .erreur:
            return DiskVerdict(limit: .service, title: "Le service signale une erreur d’envoi",
                               detail: local + " Vérifiez l’espace du compte (quota) et l’état de l’app du service.", tone: .critical)
        default:
            break
        }
        return DiskVerdict(limit: .inconnu, title: "Envoi non suivi", detail: local, tone: .neutral)
    }
}
