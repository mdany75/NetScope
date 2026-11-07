import Foundation

// Modèle des sondes de l'écran Surveillance : type, cible, intervalle, seuils, plage horaire,
// dépendance et conditions propres à chaque type. Tout est Codable (surveillance.json).

/// Type de sonde.
public enum MonProbeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case ping, tcp, http, dns, snmp, switchPort, newDevices
    /// Ressources (note 21) : processeur, mémoire, port saturé (ce Mac ou SNMP).
    case cpu, memory, portLoad
    /// État d'un grand service en ligne (note 15) : page d'état officielle et test depuis ce réseau.
    case onlineService
    /// Wi-Fi géré par la FortiGate (note 27) : borne FortiAP hors ligne, borne surchargée.
    case fortiAPOffline, fortiAPOverload
    /// Étendue DHCP presque pleine (note 37), lue par la FortiGate ou estimée par le Test DHCP.
    case dhcpScope
    /// WAN des FortiGate (note 39) : tunnel VPN IPsec tombé, lien WAN dégradé (seuils).
    case vpnTunnel, wanLink
    /// Trafic lu par FortiView (note 54) : lien WAN saturé, appareil qui consomme trop, nouvelle menace.
    case linkSaturated, heavyDevice, newThreat
    /// Parc Fortinet (note 41) : licence FortiGuard ou FortiCare bientôt expirée, firmware pas à jour.
    case licenseExpiring, firmwareOutdated
    /// Journaux (note 43) : message Syslog (ou de la FortiGate) de gravité ≥ X, trap SNMP reçue.
    case syslogSeverity, trapReceived
    /// Certificat TLS (note 70) : jours restants avant l'expiration d'un service HTTPS, LDAPS ou de courriel.
    case tlsCertificate
    /// Serveur RustDesk (note 87) : hbbs ou hbbr arrêté, disque plein, clé publique changée (lecture SSH).
    case rustdeskServer
    /// Imprimante (note 91) : consommable sous le seuil (15 % par défaut), bourrage ou bac vide (Printer-MIB).
    case printerSupply

    public var id: String { rawValue }

    /// Libellé de l'éditeur (« Ping (ICMP) »).
    public var label: String {
        switch self {
        case .ping: return "Ping (ICMP)"
        case .tcp: return "TCP"
        case .http: return "HTTP(S)"
        case .dns: return "DNS"
        case .snmp: return "SNMP"
        case .switchPort: return "Port de switch"
        case .newDevices: return "Nouveaux appareils"
        case .cpu: return "Processeur > X\u{00A0}%"
        case .memory: return "Mémoire > X\u{00A0}%"
        case .portLoad: return "Port saturé > X\u{00A0}%"
        case .onlineService: return "Service en ligne"
        case .fortiAPOffline: return "FortiAP hors ligne"
        case .fortiAPOverload: return "Borne surchargée"
        case .dhcpScope: return "Étendue DHCP presque pleine"
        case .vpnTunnel: return "Tunnel VPN tombé"
        case .wanLink: return "Lien WAN dégradé"
        case .linkSaturated: return "Lien saturé"
        case .heavyDevice: return "Appareil qui consomme trop"
        case .newThreat: return "Nouvelle menace"
        case .licenseExpiring: return "Licence bientôt expirée"
        case .firmwareOutdated: return "Firmware pas à jour"
        case .syslogSeverity: return "Message Syslog de gravité ≥ X"
        case .trapReceived: return "Trap SNMP reçue"
        case .tlsCertificate: return "Certificat TLS (jours restants)"
        case .rustdeskServer: return "Serveur RustDesk"
        case .printerSupply: return "Consommable bas (imprimante)"
        }
    }

    /// Étiquette courte de la colonne Type (« Ping », « Port »).
    public var shortLabel: String {
        switch self {
        case .ping: return "Ping"
        case .tcp: return "TCP"
        case .http: return "HTTP(S)"
        case .dns: return "DNS"
        case .snmp: return "SNMP"
        case .switchPort: return "Port"
        case .newDevices: return "Découverte"
        case .cpu: return "CPU"
        case .memory: return "Mémoire"
        case .portLoad: return "Débit"
        case .onlineService: return "Service"
        case .fortiAPOffline: return "FortiAP"
        case .fortiAPOverload: return "Charge Wi-Fi"
        case .dhcpScope: return "DHCP"
        case .vpnTunnel: return "VPN"
        case .wanLink: return "WAN"
        case .linkSaturated: return "Lien WAN"
        case .heavyDevice: return "Trafic"
        case .newThreat: return "Menace"
        case .licenseExpiring: return "Licence"
        case .firmwareOutdated: return "Firmware"
        case .syslogSeverity: return "Syslog"
        case .trapReceived: return "Trap"
        case .tlsCertificate: return "Certificat"
        case .rustdeskServer: return "RustDesk"
        case .printerSupply: return "Imprimante"
        }
    }

    /// Indication de la cible attendue.
    public var targetPlaceholder: String {
        switch self {
        case .ping: return "Adresse IP ou nom d’hôte"
        case .tcp: return "Adresse:port (10.0.0.1:443)"
        case .http: return "https://10.0.0.1"
        case .dns: return "Nom à résoudre (intranet.local)"
        case .snmp: return "Adresse IP de l’agent SNMP"
        case .switchPort: return "Adresse MAC de l’appareil"
        case .newDevices: return "Plage (10.0.0.0/24)"
        case .cpu, .memory: return "ce Mac, ou adresse IP de l’agent SNMP"
        case .portLoad: return "ce Mac, ou adresse IP du switch"
        case .onlineService: return "Service du catalogue (Microsoft 365, GitHub…)"
        case .fortiAPOffline, .fortiAPOverload: return "Nom ou numéro de série de la borne, ou «\u{00A0}*\u{00A0}» pour toutes"
        case .dhcpScope: return "Interface, VLAN ou nom de l’étendue, ou «\u{00A0}*\u{00A0}» pour toutes"
        case .vpnTunnel: return "Nom du tunnel IPsec (Siège / VPN-QUEBEC), ou «\u{00A0}*\u{00A0}» pour tous"
        case .wanLink: return "Interface ou nom du lien (Siège / wan2), ou «\u{00A0}*\u{00A0}» pour tous"
        case .linkSaturated: return "Interface WAN (wan1), ou «\u{00A0}*\u{00A0}» pour tous les liens"
        case .heavyDevice: return "Adresse IP de l’appareil, ou «\u{00A0}*\u{00A0}» pour tous"
        case .newThreat: return "Site, ou «\u{00A0}*\u{00A0}» pour tous les sites lus"
        case .licenseExpiring: return "Service (IPS, FortiCare…), «\u{00A0}Siège / *\u{00A0}», ou «\u{00A0}*\u{00A0}» pour toutes"
        case .firmwareOutdated: return "Équipement, modèle ou famille (FortiAP), «\u{00A0}Siège / *\u{00A0}», ou «\u{00A0}*\u{00A0}»"
        case .syslogSeverity, .trapReceived: return "Adresse ou nom de l’appareil, ou «\u{00A0}*\u{00A0}» pour tous"
        case .tlsCertificate: return "Hôte:port (fw.exemple.ca:443, 10.0.0.1:8443, mail.exemple.ca:587)"
        case .rustdeskServer: return "Compte SSH du serveur (admin@assistance.exemple.ca)"
        case .printerSupply: return "Adresse IP ou nom de l’imprimante (SNMP)"
        }
    }

    /// Vrai si la sonde ne dépend pas de l'inventaire du Scanner (le port de switch et les nouveaux
    /// appareils le lisent) ; les sondes de ressources de ce Mac n'envoient rien sur le réseau.
    public var usesNetwork: Bool {
        switch self {
        case .switchPort, .newDevices: return false
        default: return true
        }
    }
}

/// Plage horaire pendant laquelle une sonde peut créer des alertes (elle s'exécute toujours).
public enum MonSchedule: String, Codable, CaseIterable, Sendable, Identifiable {
    case always, businessHours, offHours

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .always: return "Toujours (24 h sur 24, 7 j sur 7)"
        case .businessHours: return "Heures ouvrables du site"
        case .offHours: return "Hors heures ouvrables seulement"
        }
    }

    /// Note 78 : libellé avec l'horaire du site (« Heures ouvrables du site (lun.–ven. 7 h – 18 h) »).
    public func label(hours: MonBusinessHours) -> String {
        switch self {
        case .always: return label
        case .businessHours: return "Heures ouvrables du site (\(hours.summary))"
        case .offHours: return "Hors heures ouvrables du site seulement"
        }
    }

    /// Heures ouvrables : du lundi au vendredi, de 7 h à 18 h (18 h exclue).
    public static func isBusinessHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date) // 1 = dimanche
        let hour = calendar.component(.hour, from: date)
        return (2...6).contains(weekday) && (7..<18).contains(hour)
    }

    /// Vrai si une alerte peut être créée à cette date (horaire standard lun.–ven. 7 h – 18 h).
    public func allowsAlerts(at date: Date, calendar: Calendar = .current) -> Bool {
        allowsAlerts(at: date, hours: .standard, calendar: calendar)
    }

    /// Note 78 : vrai si une alerte peut être créée à cette date, selon les heures ouvrables du site.
    public func allowsAlerts(at date: Date, hours: MonBusinessHours, calendar: Calendar = .current) -> Bool {
        switch self {
        case .always: return true
        case .businessHours: return hours.contains(date, calendar: calendar)
        case .offHours: return !hours.contains(date, calendar: calendar)
        }
    }
}

/// Seuils d'alerte communs.
public struct MonThresholds: Codable, Equatable, Sendable {
    /// Latence au-delà de laquelle la sonde passe en avertissement (ms) ; nil : pas de seuil.
    public var latencyMs: Double?
    /// Perte au-delà de laquelle la sonde passe en avertissement (%) ; nil : pas de seuil.
    public var lossPercent: Double?
    /// Échecs consécutifs avant de déclarer la panne (au moins 1).
    public var failures: Int

    public init(latencyMs: Double? = 50, lossPercent: Double? = 5, failures: Int = 3) {
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
        self.failures = max(1, failures)
    }
}

/// Comparaison d'une valeur numérique (SNMP).
public enum MonComparison: String, Codable, CaseIterable, Sendable, Identifiable {
    case greater, less, equal, notEqual

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .greater: return ">"
        case .less: return "<"
        case .equal: return "="
        case .notEqual: return "≠"
        }
    }

    /// Vrai si la condition d'alerte est remplie.
    public func matches(_ value: Double, _ limit: Double) -> Bool {
        switch self {
        case .greater: return value > limit
        case .less: return value < limit
        case .equal: return value == limit
        case .notEqual: return value != limit
        }
    }
}

/// Une sonde de surveillance.
public struct MonProbe: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: MonProbeKind
    /// Adresse, URL, nom, MAC ou plage selon le type.
    public var target: String
    /// Précision affichée sous la cible (« FortiGate-60F »).
    public var subtitle: String
    public var isEnabled: Bool
    /// Intervalle entre deux vérifications, en secondes.
    public var interval: Int
    public var thresholds: MonThresholds
    public var schedule: MonSchedule
    /// Sonde dont dépend celle-ci : si elle est en panne, les échecs de celle-ci sont ignorés.
    public var dependsOn: UUID?
    public var notify: Bool
    public var sound: Bool

    // Conditions propres au type (nil : non utilisées).
    /// Ping : port TCP essayé en repli quand l'ICMP ne répond pas (caméra qui bloque le ping).
    public var fallbackPort: UInt16?
    /// HTTP(S) : code attendu (200 par défaut).
    public var expectedStatus: Int?
    /// HTTP(S) : mot-clé qui doit figurer dans la page.
    public var keyword: String?
    /// HTTP(S) : avertir quand le certificat expire dans moins de N jours.
    public var certificateDays: Int?
    /// DNS : serveur interrogé (nil : résolveur du système).
    public var dnsServer: String?
    /// DNS : adresse attendue dans la réponse.
    public var dnsExpected: String?
    /// SNMP : OID lu, comparaison et limite.
    public var snmpOID: String?
    public var snmpComparison: MonComparison?
    public var snmpLimit: Double?
    /// SNMP : unité affichée après la valeur (« °C », « dBm »).
    public var snmpUnit: String?
    /// Port de switch : emplacement attendu (« SW-CORE-01 · Gi1/0/22 »), appris au premier passage.
    public var expectedLocation: String?
    /// Nouveaux appareils : adresses MAC déjà connues sur la plage.
    public var knownMACs: [String]?
    /// Ressources : seuil d'alerte en pourcentage (processeur, mémoire, charge du lien).
    public var resourceLimit: Double?
    /// Port saturé : nom du port (« Gi1/0/48 », « en0 »).
    public var resourcePort: String?
    /// Borne surchargée (note 27) : seuils de clients par radio et d'utilisation du canal.
    public var wifiThresholds: FortiWifiThresholds?
    /// Étendue DHCP presque pleine (note 37) : seuils d'occupation propres à la sonde.
    public var dhcpThresholds: DHCPScopeThresholds?
    /// Lien WAN dégradé (note 39) : seuils de latence, de gigue et de perte propres à la sonde.
    public var wanThresholds: WANThresholds?
    /// Nouvelle menace (note 54) : menaces déjà vues (clés « site|menace|adresse »), apprises au premier passage.
    public var knownThreats: [String]?
    /// Message Syslog (note 43) : gravité minimale qui déclenche l'alerte (nil : erreur).
    public var logSeverity: LogSeverity?
    /// Trap reçue (note 43) : nom ou OID de la trap attendue (nil ou vide : toutes).
    public var trapFilter: String?
    /// Note 78 : site de la sonde (heures ouvrables, maintenance, rapport) ; nil : déduit de la cible.
    public var siteID: UUID?
    /// Serveur RustDesk (note 87) : paramètres non secrets du compte SSH du tableau de bord, pour
    /// que l'agent lise comme l'app : clé privée (chemin), rebond (-J) et connexion du carnet dont
    /// le mot de passe est au Trousseau (nil : compte saisi).
    public var sshKeyPath: String?
    public var sshJump: String?
    public var sshConnection: UUID?

    public init(id: UUID = UUID(), name: String, kind: MonProbeKind, target: String, subtitle: String = "",
                isEnabled: Bool = true, interval: Int = 60, thresholds: MonThresholds = MonThresholds(),
                schedule: MonSchedule = .always, dependsOn: UUID? = nil, notify: Bool = true, sound: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.interval = max(5, interval)
        self.thresholds = thresholds
        self.schedule = schedule
        self.dependsOn = dependsOn
        self.notify = notify
        self.sound = sound
    }

    /// Intervalles proposés par l'éditeur (secondes).
    public static let intervals = [10, 30, 60, 300, 900, 3600, 43_200]

    /// « 10 s », « 5 min », « 1 h », « 12 h ».
    public static func intervalLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)\u{00A0}s" }
        if seconds == 60 { return "60\u{00A0}s" }
        if seconds < 3600 { return "\(seconds / 60)\u{00A0}min" }
        return "\(seconds / 3600)\u{00A0}h"
    }

    /// « Toutes les 10 s », « Toutes les heures ».
    public static func intervalMenuLabel(_ seconds: Int) -> String {
        seconds == 3600 ? "Toutes les heures" : "Toutes les \(intervalLabel(seconds))"
    }

    /// Résumé de la condition propre au type (« Code HTTP attendu : 200 »).
    public var conditionSummary: String {
        let nbsp = "\u{00A0}"
        switch kind {
        case .ping:
            return fallbackPort.map { "ICMP puis TCP \($0) en repli" } ?? ""
        case .tcp:
            return "Port attendu\(nbsp): ouvert"
        case .http:
            var parts = ["Code HTTP attendu\(nbsp): \(expectedStatus ?? 200)"]
            if let keyword, !keyword.isEmpty { parts.append("mot-clé «\(nbsp)\(keyword)\(nbsp)»") }
            if let days = certificateDays { parts.append("certificat > \(days)\(nbsp)j") }
            return parts.joined(separator: " · ")
        case .dns:
            return dnsExpected.flatMap { $0.isEmpty ? nil : "Réponse attendue\(nbsp): \($0)" } ?? "Réponse non vide"
        case .snmp:
            guard let oid = snmpOID, !oid.isEmpty else { return "" }
            guard let comparison = snmpComparison, let limit = snmpLimit else { return "OID \(oid)" }
            return "Alerte si \(oid) \(comparison.symbol) \(MonFormat.number(limit))\(snmpUnit.map { nbsp + $0 } ?? "")"
        case .switchPort:
            return expectedLocation.map { "Alerte si l’appareil quitte \($0)" } ?? "Alerte si l’appareil change de port"
        case .newDevices:
            return "Alerte à chaque nouvelle adresse MAC"
        case .cpu:
            return "Alerte si processeur > \(MonFormat.percent(resourceLimit ?? MonProbe.defaultResourceLimit(.cpu)))"
        case .memory:
            return "Alerte si mémoire > \(MonFormat.percent(resourceLimit ?? MonProbe.defaultResourceLimit(.memory)))"
        case .portLoad:
            let port = resourcePort.flatMap { $0.isEmpty ? nil : $0 } ?? "port à choisir"
            return "Alerte si \(port) > \(MonFormat.percent(resourceLimit ?? MonProbe.defaultResourceLimit(.portLoad))) du lien"
        case .onlineService:
            return "Alerte si panne chez eux, dégradé ou injoignable d’ici"
        case .fortiAPOffline:
            return "Alerte si la FortiGate voit la borne déconnectée"
        case .fortiAPOverload:
            let t = wifiThresholds ?? .standard
            return "Alerte au-delà de \(t.maxClientsPerRadio) clients par radio ou \(MonFormat.percent(t.maxChannelUtilization)) d’utilisation du canal"
        case .dhcpScope:
            let t = dhcpThresholds ?? .standard
            return "Alerte à \(MonFormat.percent(t.warningPercent)) d’occupation, critique à \(MonFormat.percent(t.criticalPercent))"
        case .vpnTunnel:
            return "Panne si un tunnel est tombé, alerte si une phase 2 manque"
        case .wanLink:
            return "Panne si le lien tombe, alerte si " + (wanThresholds ?? .standard).label
        case .linkSaturated:
            return "Alerte si le lien dépasse \(MonFormat.percent(resourceLimit ?? MonProbe.defaultResourceLimit(.linkSaturated))) de sa capacité"
        case .heavyDevice:
            return "Alerte si un appareil dépasse \(MonFormat.number(resourceLimit ?? MonProbe.defaultResourceLimit(.heavyDevice)))\u{00A0}Mb/s"
        case .newThreat:
            return "Alerte à chaque nouvelle menace vue par FortiView" + (knownThreats.map { " (\($0.count) connues)" } ?? "")
        case .licenseExpiring:
            let days = Int(resourceLimit ?? MonProbe.defaultResourceLimit(.licenseExpiring))
            return "Alerte si une licence expire dans \(days)\u{00A0}j ou moins, panne si elle est expirée"
        case .firmwareOutdated:
            return "Alerte si une version plus récente est disponible (aucune mise à jour lancée)"
        case .syslogSeverity:
            return "Alerte à chaque message de gravité \((logSeverity ?? .error).atLeastLabel) reçu"
        case .trapReceived:
            let filter = trapFilter?.trimmingCharacters(in: .whitespaces) ?? ""
            return filter.isEmpty ? "Alerte à chaque trap reçue" : "Alerte à chaque trap «\(nbsp)\(filter)\(nbsp)» reçue"
        case .tlsCertificate:
            let days = Int(resourceLimit ?? MonProbe.defaultResourceLimit(.tlsCertificate))
            return "Alerte si le certificat expire dans \(days)\(nbsp)j ou moins, panne s’il est expiré"
        case .rustdeskServer:
            let limit = Int(resourceLimit ?? MonProbe.defaultResourceLimit(.rustdeskServer))
            return "Alerte si hbbs ou hbbr s’arrête, si le disque dépasse \(limit)\(nbsp)% ou si la clé publique change"
        case .printerSupply:
            let limit = Int(resourceLimit ?? MonProbe.defaultResourceLimit(.printerSupply))
            return "Alerte si un consommable descend à \(limit)\(nbsp)% ou moins, panne si l’impression est bloquée (bourrage, bac vide)"
        }
    }

    /// Seuil proposé pour une sonde de ressources (90 % processeur et mémoire, 80 % pour un port).
    public static func defaultResourceLimit(_ kind: MonProbeKind) -> Double {
        switch kind {
        case .portLoad, .linkSaturated: return 80
        case .heavyDevice: return 50
        case .licenseExpiring: return Double(MonFirmwareChecks.defaultDays)
        case .tlsCertificate: return Double(MonTLSChecks.defaultDays)
        case .printerSupply: return PrinterMIB.defaultThreshold
        default: return 90
        }
    }

    /// Hôte et port d'une cible TCP (« 10.0.0.1:443 »).
    public static func hostAndPort(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !host.isEmpty, let port = UInt16(trimmed[trimmed.index(after: colon)...]), port > 0 else { return nil }
        return (host, port)
    }
}

// MARK: Décodage tolérant
//
// surveillance.json peut venir d'une autre version de NetScope : un champ manquant prend sa valeur
// par défaut, une valeur inconnue (plage horaire, comparaison) aussi ; seul un type de sonde
// inconnu rend la sonde illisible (elle est alors écartée, pas tout le fichier).

extension MonThresholds {
    private enum Keys: String, CodingKey { case latencyMs, lossPercent, failures }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(latencyMs: try? container.decodeIfPresent(Double.self, forKey: .latencyMs),
                  lossPercent: try? container.decodeIfPresent(Double.self, forKey: .lossPercent),
                  failures: (try? container.decodeIfPresent(Int.self, forKey: .failures)) ?? 3)
    }
}

extension MonProbe {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Sonde",
                  kind: try c.decode(MonProbeKind.self, forKey: .kind),
                  target: (try? c.decodeIfPresent(String.self, forKey: .target)) ?? "",
                  subtitle: (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? "",
                  isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true,
                  interval: (try? c.decodeIfPresent(Int.self, forKey: .interval)) ?? 60,
                  thresholds: (try? c.decodeIfPresent(MonThresholds.self, forKey: .thresholds)) ?? MonThresholds(),
                  schedule: (try? c.decodeIfPresent(MonSchedule.self, forKey: .schedule)) ?? .always,
                  dependsOn: try? c.decodeIfPresent(UUID.self, forKey: .dependsOn),
                  notify: (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? true,
                  sound: (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? false)
        fallbackPort = try? c.decodeIfPresent(UInt16.self, forKey: .fallbackPort)
        expectedStatus = try? c.decodeIfPresent(Int.self, forKey: .expectedStatus)
        keyword = try? c.decodeIfPresent(String.self, forKey: .keyword)
        certificateDays = try? c.decodeIfPresent(Int.self, forKey: .certificateDays)
        dnsServer = try? c.decodeIfPresent(String.self, forKey: .dnsServer)
        dnsExpected = try? c.decodeIfPresent(String.self, forKey: .dnsExpected)
        snmpOID = try? c.decodeIfPresent(String.self, forKey: .snmpOID)
        snmpComparison = try? c.decodeIfPresent(MonComparison.self, forKey: .snmpComparison)
        snmpLimit = try? c.decodeIfPresent(Double.self, forKey: .snmpLimit)
        snmpUnit = try? c.decodeIfPresent(String.self, forKey: .snmpUnit)
        expectedLocation = try? c.decodeIfPresent(String.self, forKey: .expectedLocation)
        knownMACs = try? c.decodeIfPresent([String].self, forKey: .knownMACs)
        resourceLimit = try? c.decodeIfPresent(Double.self, forKey: .resourceLimit)
        resourcePort = try? c.decodeIfPresent(String.self, forKey: .resourcePort)
        wifiThresholds = try? c.decodeIfPresent(FortiWifiThresholds.self, forKey: .wifiThresholds)
        dhcpThresholds = try? c.decodeIfPresent(DHCPScopeThresholds.self, forKey: .dhcpThresholds)
        wanThresholds = try? c.decodeIfPresent(WANThresholds.self, forKey: .wanThresholds)
        knownThreats = try? c.decodeIfPresent([String].self, forKey: .knownThreats)
        logSeverity = try? c.decodeIfPresent(LogSeverity.self, forKey: .logSeverity)
        trapFilter = try? c.decodeIfPresent(String.self, forKey: .trapFilter)
        siteID = try? c.decodeIfPresent(UUID.self, forKey: .siteID)
        sshKeyPath = try? c.decodeIfPresent(String.self, forKey: .sshKeyPath)
        sshJump = try? c.decodeIfPresent(String.self, forKey: .sshJump)
        sshConnection = try? c.decodeIfPresent(UUID.self, forKey: .sshConnection)
    }
}

/// Élément d'un tableau lu sans faire échouer le tableau entier : nil s'il est illisible.
struct MonLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Mise en forme commune (typographie française, espaces insécables).
public enum MonFormat {
    /// « 41 », « 2,5 ».
    public static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(value.clampedInt) : ToolFormat.decimal(value)
    }

    /// « 0 % », « 12,5 % ».
    public static func percent(_ value: Double) -> String {
        (value == value.rounded() && abs(value) < 1e12 ? String(value.clampedInt) : ToolFormat.decimal(value)) + "\u{00A0}%"
    }
}
