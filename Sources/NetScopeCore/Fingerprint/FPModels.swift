import Foundation

// Note 68 : empreinte légère des services et du système, sans Nmap ni base de CVE. Tout part de ce
// que NetScope lit déjà, ou lit pendant un scan de ports demandé par l'utilisateur : bannières (SSH,
// FTP, SMTP, Telnet), en-têtes HTTP (Server, X-Powered-By) et titre de page, certificat TLS (sujet,
// émetteur), dialecte SMB (négociation SMB2 seule, sans authentification), sysDescr SNMP, TXT mDNS
// et TTL des réponses au ping. Les règles (FPServiceRules, FPSystemRules) sont pures : aucun accès
// réseau, testées sur des réponses recopiées.

/// Confiance d'une déduction.
public enum FPConfidence: Int, Codable, Comparable, Sendable, CaseIterable {
    case faible = 1, moyenne = 2, forte = 3

    public static func < (lhs: FPConfidence, rhs: FPConfidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .faible: return "faible"
        case .moyenne: return "moyenne"
        case .forte: return "forte"
        }
    }
}

/// D'où vient un indice.
public enum FPSource: String, Codable, Sendable, CaseIterable {
    case http, title, tls, smb, ssh, ftp, smtp, telnet, banner, snmp, mdns, ttl, ports, vendor

    public var label: String {
        switch self {
        case .http: return "En-tête HTTP"
        case .title: return "Titre de la page"
        case .tls: return "Certificat TLS"
        case .smb: return "Négociation SMB"
        case .ssh: return "Bannière SSH"
        case .ftp: return "Bannière FTP"
        case .smtp: return "Bannière SMTP"
        case .telnet: return "Bannière Telnet"
        case .banner: return "Bannière"
        case .snmp: return "sysDescr SNMP"
        case .mdns: return "TXT mDNS"
        case .ttl: return "TTL"
        case .ports: return "Ports ouverts"
        case .vendor: return "Fabricant (OUI)"
        }
    }
}

/// Un indice : ce qui a été lu, et ce qu'on en tire.
public struct FPClue: Codable, Hashable, Sendable {
    public var source: FPSource
    /// Ce qui a été lu, tel quel ou presque (« Server: Microsoft-IIS/10.0 »).
    public var observed: String
    /// Ce qu'on en déduit (« Windows Server 2016 ou plus récent »).
    public var conclusion: String
    public var weight: FPConfidence
    /// Port d'où vient l'indice (nil : SNMP, TTL, mDNS…).
    public var port: UInt16?

    public init(source: FPSource, observed: String, conclusion: String, weight: FPConfidence, port: UInt16? = nil) {
        self.source = source
        self.observed = observed
        self.conclusion = conclusion
        self.weight = weight
        self.port = port
    }

    /// « Certificat TLS (443) : O=Fortinet → FortiGate ».
    public var line: String {
        let where_ = port.map { " (\($0))" } ?? ""
        return "\(source.label)\(where_)\u{00A0}: \(observed) → \(conclusion)"
    }
}

/// Nom distinctif d'un certificat (les seuls attributs utiles ici).
public struct FPCertName: Codable, Hashable, Sendable {
    public var commonName: String?
    public var organization: String?
    public var organizationalUnit: String?

    public init(commonName: String? = nil, organization: String? = nil, organizationalUnit: String? = nil) {
        self.commonName = commonName
        self.organization = organization
        self.organizationalUnit = organizationalUnit
    }

    public var isEmpty: Bool { commonName == nil && organization == nil && organizationalUnit == nil }

    /// « CN=FGT60FTK2109ABCD, O=Fortinet, OU=FortiGate ».
    public var summary: String {
        [commonName.map { "CN=\($0)" }, organization.map { "O=\($0)" }, organizationalUnit.map { "OU=\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Tous les attributs, pour chercher une marque.
    var allText: String { [commonName, organization, organizationalUnit].compactMap { $0 }.joined(separator: " ") }
}

/// Ce qu'un service a répondu pendant un scan de ports (bannière, HTTP, TLS, SMB). Rien d'autre
/// n'est gardé : ni corps de page, ni secret.
public struct FPServiceObservation: Codable, Hashable, Sendable {
    public var port: UInt16
    /// Première ligne de bannière (SSH, FTP, SMTP, Telnet, VNC…).
    public var banner: String?
    /// « HTTP/1.1 200 OK ».
    public var httpStatus: String?
    public var httpServer: String?
    public var httpPoweredBy: String?
    /// Domaine d'authentification (WWW-Authenticate realm), souvent le modèle d'un appareil.
    public var httpRealm: String?
    public var httpTitle: String?
    /// Vrai si le service a répondu en TLS.
    public var tls: Bool
    public var certSubject: FPCertName?
    public var certIssuer: FPCertName?
    public var certSelfSigned: Bool?
    public var certNotAfter: Date?
    /// Dialecte SMB2/3 négocié (0x0311 : SMB 3.1.1).
    public var smbDialect: UInt16?
    /// Le serveur n'a répondu qu'en SMB1.
    public var smb1Only: Bool?
    public var smbSigningRequired: Bool?
    /// Indice SPNEGO propre à Samba (« not_defined_in_RFC4178@please_ignore »).
    public var smbSambaHint: Bool?
    public var observedAt: Date?

    public init(port: UInt16, banner: String? = nil, httpStatus: String? = nil, httpServer: String? = nil,
                httpPoweredBy: String? = nil, httpRealm: String? = nil, httpTitle: String? = nil, tls: Bool = false,
                certSubject: FPCertName? = nil, certIssuer: FPCertName? = nil, certSelfSigned: Bool? = nil,
                certNotAfter: Date? = nil, smbDialect: UInt16? = nil, smb1Only: Bool? = nil,
                smbSigningRequired: Bool? = nil, smbSambaHint: Bool? = nil, observedAt: Date? = nil) {
        self.port = port
        self.banner = banner
        self.httpStatus = httpStatus
        self.httpServer = httpServer
        self.httpPoweredBy = httpPoweredBy
        self.httpRealm = httpRealm
        self.httpTitle = httpTitle
        self.tls = tls
        self.certSubject = certSubject
        self.certIssuer = certIssuer
        self.certSelfSigned = certSelfSigned
        self.certNotAfter = certNotAfter
        self.smbDialect = smbDialect
        self.smb1Only = smb1Only
        self.smbSigningRequired = smbSigningRequired
        self.smbSambaHint = smbSambaHint
        self.observedAt = observedAt
    }

    /// Rien d'exploitable n'a été lu.
    public var isEmpty: Bool {
        banner == nil && httpStatus == nil && httpServer == nil && httpPoweredBy == nil && httpRealm == nil
            && httpTitle == nil && certSubject == nil && certIssuer == nil && smbDialect == nil && smb1Only == nil
    }

    /// Complète cette observation par une plus récente du même port (les champs lus l'emportent).
    public func updated(with newer: FPServiceObservation) -> FPServiceObservation {
        var result = self
        result.banner = newer.banner ?? banner
        result.httpStatus = newer.httpStatus ?? httpStatus
        result.httpServer = newer.httpServer ?? httpServer
        result.httpPoweredBy = newer.httpPoweredBy ?? httpPoweredBy
        result.httpRealm = newer.httpRealm ?? httpRealm
        result.httpTitle = newer.httpTitle ?? httpTitle
        result.tls = newer.tls || tls
        result.certSubject = newer.certSubject ?? certSubject
        result.certIssuer = newer.certIssuer ?? certIssuer
        result.certSelfSigned = newer.certSelfSigned ?? certSelfSigned
        result.certNotAfter = newer.certNotAfter ?? certNotAfter
        result.smbDialect = newer.smbDialect ?? smbDialect
        result.smb1Only = newer.smb1Only ?? smb1Only
        result.smbSigningRequired = newer.smbSigningRequired ?? smbSigningRequired
        result.smbSambaHint = newer.smbSambaHint ?? smbSambaHint
        result.observedAt = newer.observedAt ?? observedAt
        return result
    }
}

/// Tout ce qui est connu d'un appareil pour l'empreinte, gardé avec l'appareil (Device.fingerprint).
public struct FPEvidence: Codable, Hashable, Sendable {
    /// Une observation par port, triées par port.
    public var services: [FPServiceObservation]
    public var sysDescr: String?
    public var sysObjectID: String?
    /// TXT mDNS (clés en minuscules) : « md », « model », « ty », « vendor »…
    public var mdnsTXT: [String: String]
    /// TTL de la dernière réponse au ping.
    public var ttl: Int?

    public init(services: [FPServiceObservation] = [], sysDescr: String? = nil, sysObjectID: String? = nil,
                mdnsTXT: [String: String] = [:], ttl: Int? = nil) {
        self.services = services.sorted { $0.port < $1.port }
        self.sysDescr = sysDescr
        self.sysObjectID = sysObjectID
        self.mdnsTXT = mdnsTXT
        self.ttl = ttl
    }

    public var isEmpty: Bool { services.isEmpty && sysDescr == nil && mdnsTXT.isEmpty && ttl == nil }

    public func service(_ port: UInt16) -> FPServiceObservation? { services.first { $0.port == port } }

    /// Ajoute ou complète l'observation d'un port ; une observation vide ne change rien.
    public mutating func record(_ observation: FPServiceObservation) {
        guard !observation.isEmpty else { return }
        if let index = services.firstIndex(where: { $0.port == observation.port }) {
            services[index] = services[index].updated(with: observation)
        } else {
            services.append(observation)
            services.sort { $0.port < $1.port }
        }
    }

    /// Ce qu'on savait (`known`), complété par ce qui vient d'être lu (`incoming`).
    public static func merged(_ known: FPEvidence?, _ incoming: FPEvidence?) -> FPEvidence? {
        guard let incoming else { return known }
        guard var result = known else { return incoming.isEmpty ? nil : incoming }
        for service in incoming.services { result.record(service) }
        result.sysDescr = incoming.sysDescr ?? result.sysDescr
        result.sysObjectID = incoming.sysObjectID ?? result.sysObjectID
        result.mdnsTXT.merge(incoming.mdnsTXT) { _, new in new }
        result.ttl = incoming.ttl ?? result.ttl
        return result
    }
}

/// Ce qu'on tire d'un service.
public struct FPServiceResult: Hashable, Sendable, Identifiable {
    public var id: UInt16 { port }
    public var port: UInt16
    /// Produit (« OpenSSH », « Microsoft IIS », « FortiGate »).
    public var product: String?
    public var version: String?
    /// Système que le service trahit (« Ubuntu », « Windows »).
    public var system: String?
    /// Protocole en clair (Telnet, FTP, HTTP sans TLS…) : nom court, sinon nil.
    public var clearText: String?
    public var clues: [FPClue]
    public var confidence: FPConfidence
    /// La version est celle du protocole (SMB 3.1.1, RFB 3.8), pas celle d'un logiciel.
    public var isProtocolVersion: Bool

    public init(port: UInt16, product: String? = nil, version: String? = nil, system: String? = nil,
                clearText: String? = nil, clues: [FPClue] = [], confidence: FPConfidence = .faible,
                isProtocolVersion: Bool = false) {
        self.port = port
        self.product = product
        self.version = version
        self.system = system
        self.clearText = clearText
        self.clues = clues
        self.confidence = confidence
        self.isProtocolVersion = isProtocolVersion
    }

    /// « OpenSSH 8.9p1 », « nginx », nil si rien n'est reconnu.
    public var productLabel: String? {
        guard let product else { return version }
        return version.map { "\(product) \($0)" } ?? product
    }

    /// La version est annoncée (utile au rapport Sécurité).
    public var exposesVersion: Bool { version != nil && !isProtocolVersion }
}

/// Famille de système, pour regrouper des indices concordants.
public enum FPSystemFamily: String, Codable, Sendable, CaseIterable {
    case windows, linux, macos, bsd, fortios, routeros, ciscoIOS, arubaOS, junos, ubiquiti, dsm, qts,
         printer, camera, esxi, bmc, embedded, network

    /// Nom affiché quand aucun indice plus précis n'est connu.
    public var label: String {
        switch self {
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .macos: return "macOS"
        case .bsd: return "BSD"
        case .fortios: return "FortiOS"
        case .routeros: return "MikroTik RouterOS"
        case .ciscoIOS: return "Cisco IOS"
        case .arubaOS: return "ArubaOS"
        case .junos: return "Junos"
        case .ubiquiti: return "Ubiquiti"
        case .dsm: return "Synology DSM"
        case .qts: return "QNAP QTS"
        case .printer: return "Micrologiciel d’imprimante"
        case .camera: return "Micrologiciel de caméra"
        case .esxi: return "VMware ESXi"
        case .bmc: return "Contrôleur de gestion (BMC)"
        case .embedded: return "Système embarqué"
        case .network: return "Équipement réseau"
        }
    }
}

/// Système déduit, avec sa confiance et ses indices.
public struct FPSystemResult: Hashable, Sendable {
    public var family: FPSystemFamily
    /// Nom précis (« Windows Server », « Ubuntu », « FortiGate »), sinon le nom de la famille.
    public var name: String
    public var version: String?
    /// Type d'appareil que le système indique (nil : rien de sûr).
    public var deviceType: DeviceType?
    public var confidence: FPConfidence
    public var clues: [FPClue]

    public init(family: FPSystemFamily, name: String, version: String? = nil, deviceType: DeviceType? = nil,
                confidence: FPConfidence, clues: [FPClue]) {
        self.family = family
        self.name = name
        self.version = version
        self.deviceType = deviceType
        self.confidence = confidence
        self.clues = clues
    }

    /// « Windows Server · 2016 ou plus récent », « Ubuntu Linux ».
    public var label: String {
        version.map { "\(name) \($0)" } ?? name
    }
}

/// Empreinte complète d'un appareil.
public struct FPReport: Hashable, Sendable {
    public var system: FPSystemResult?
    public var services: [FPServiceResult]

    public init(system: FPSystemResult? = nil, services: [FPServiceResult] = []) {
        self.system = system
        self.services = services
    }

    public var isEmpty: Bool { system == nil && services.allSatisfy { $0.productLabel == nil && $0.clearText == nil } }

    /// Type d'appareil à retenir : seulement quand l'indice est fort.
    public var strongType: DeviceType? {
        guard let system, system.confidence == .forte else { return nil }
        return system.deviceType
    }

    /// Versions annoncées (« OpenSSH 8.9p1 · nginx 1.18.0 »), dans l'ordre des ports.
    public var versionsLabel: String? {
        let labels = services.filter(\.exposesVersion).compactMap(\.productLabel)
        var seen = Set<String>()
        let unique = labels.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    public func service(_ port: UInt16) -> FPServiceResult? { services.first { $0.port == port } }
}
