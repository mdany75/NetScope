import Foundation

/// Types de services Bonjour connus : source unique des libellés français et de la liste furetée
/// directement (la même liste que NSBonjourServices dans Resources/Info.plist).
public enum BonjourCatalog {
    /// Requête qui demande aux appareils quels types ils annoncent (RFC 6763, section 9).
    public static let enumerationType = "_services._dns-sd._udp"

    private static let entries: [(type: String, label: String)] = [
        ("_http._tcp", "Site web (HTTP)"),
        ("_https._tcp", "Site web sécurisé (HTTPS)"),
        ("_ipp._tcp", "Imprimante IPP"),
        ("_ipps._tcp", "Imprimante IPP sécurisée"),
        ("_printer._tcp", "Imprimante LPD"),
        ("_pdl-datastream._tcp", "Imprimante réseau (port 9100)"),
        ("_privet._tcp", "Imprimante Privet"),
        ("_scanner._tcp", "Numériseur"),
        ("_uscan._tcp", "Numériseur eSCL"),
        ("_uscans._tcp", "Numériseur eSCL sécurisé"),
        ("_smb._tcp", "Partage SMB"),
        ("_afpovertcp._tcp", "Partage AFP"),
        ("_nfs._tcp", "Partage NFS"),
        ("_webdav._tcp", "Partage WebDAV"),
        ("_webdavs._tcp", "Partage WebDAV sécurisé"),
        ("_ftp._tcp", "Serveur FTP"),
        ("_adisk._tcp", "Sauvegarde Time Machine"),
        ("_ssh._tcp", "Accès SSH"),
        ("_sftp-ssh._tcp", "Transfert SFTP"),
        ("_telnet._tcp", "Accès Telnet"),
        ("_rfb._tcp", "Partage d’écran (VNC)"),
        ("_rdp._tcp", "Bureau à distance (RDP)"),
        ("_workstation._tcp", "Poste de travail"),
        ("_device-info._tcp", "Informations sur l’appareil"),
        ("_airplay._tcp", "AirPlay"),
        ("_raop._tcp", "AirPlay audio"),
        ("_companion-link._tcp", "Liaison entre appareils Apple"),
        ("_sleep-proxy._udp", "Proxy de veille Bonjour"),
        ("_airport._tcp", "Borne AirPort"),
        ("_daap._tcp", "Bibliothèque musicale partagée"),
        ("_dacp._tcp", "Télécommande de musique"),
        ("_googlecast._tcp", "Google Cast"),
        ("_spotify-connect._tcp", "Spotify Connect"),
        ("_sonos._tcp", "Enceinte Sonos"),
        ("_amzn-wplay._tcp", "Amazon Fire TV"),
        ("_homekit._tcp", "HomeKit"),
        ("_hap._tcp", "Accessoire HomeKit"),
        ("_hap._udp", "Accessoire HomeKit (Thread)"),
        ("_matter._tcp", "Accessoire Matter"),
        ("_matterc._udp", "Accessoire Matter à appairer"),
        ("_meshcop._udp", "Routeur de bordure Thread"),
        ("_esphomelib._tcp", "Module ESPHome"),
        ("_mqtt._tcp", "Courtier MQTT"),
        ("_sip._udp", "Téléphonie SIP"),
        ("_ptp._tcp", "Transfert d’images PTP"),
        ("_rtsp._tcp", "Flux vidéo RTSP"),
        ("_axis-video._tcp", "Caméra Axis"),
    ]

    private static let labels = Dictionary(uniqueKeysWithValues: entries.map { ($0.type, $0.label) })

    /// Types furetés dès le départ.
    public static let types: [String] = entries.map(\.type)

    public static func isKnown(_ type: String) -> Bool { labels[normalized(type)] != nil }

    /// « _IPP._tcp.local. » → « _ipp._tcp ».
    public static func normalized(_ type: String) -> String {
        var text = type.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        if text.hasSuffix(".local") { text.removeLast(".local".count) }
        return text
    }

    /// Libellé français d'un type ; un type inconnu reste reconnaissable (« Service foo (TCP) »).
    public static func label(for type: String) -> String {
        let key = normalized(type)
        if let label = labels[key] { return label }
        let parts = key.split(separator: ".").map { $0.hasPrefix("_") ? String($0.dropFirst()) : String($0) }
        guard parts.count == 2 else { return "Service \(key)" }
        return "Service \(parts[0]) (\(parts[1].uppercased()))"
    }

    /// Réponse à la requête d'énumération : le nom porte « _http » et le type « _tcp.local. ».
    public static func typeFromEnumeration(name: String, type: String) -> String? {
        let protocolName = normalized(type)
        guard name.hasPrefix("_"), name.count > 1, protocolName == "_tcp" || protocolName == "_udp" else { return nil }
        return normalized("\(name).\(protocolName)")
    }
}
