import Foundation
import NetScopeCore

/// Note 69 : scan UDP ciblé de démonstration, sans jamais rien envoyer (aucun trafic).
///
/// - imprimante Brother de l'accueil (10.182.122.111, fiche de départ) : déjà scannée avec
///   «  public  » choisie, SNMP v2c ouvert en public (constat élevé), mDNS et NetBIOS ;
/// - téléphone Yealink de l'accueil (10.182.122.121) : SIP exposé ;
/// - contrôleur de domaine (10.10.0.10) : DNS, NTP (w32time) et NetBIOS ;
/// - passerelle FortiGate (10.182.122.1) : DNS, NTP, SNMP v3 ; ports muets (aucun ICMP) ;
/// - tout autre hôte : réponses plausibles d'après le type et le fabricant de l'appareil.
///
/// Captures : NETSCOPE_DEVICE_TAB=ports montre la section « Services UDP » de la fiche ;
/// NETSCOPE_UDP_FEUILLE=1 dessine la feuille du Scanner par-dessus la fiche Appareil ;
/// NETSCOPE_OUTIL_DEMO=ports NETSCOPE_PORTS_UDP=1 ouvre l'outil Scan de ports en UDP ciblé.
@MainActor
enum UDPScanDemo {
    static let printer = "10.182.122.111"
    static let phone = "10.182.122.121"
    static let controller = "10.10.0.10"
    static let gateway = "10.182.122.1"

    static var showsSheet: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_UDP_FEUILLE"] != nil
    }

    /// Hôtes déjà scannés au lancement de la démonstration.
    static func initialStates(now: Date = Date()) -> [String: UDPHostState] {
        var states: [String: UDPHostState] = [:]
        for (host, minutes, choice, note) in [(printer, 3.0, UDPCommunityChoice.publique, "communauté «\u{00A0}public\u{00A0}»"),
                                              (phone, 26.0, .site, "communauté du site"),
                                              (controller, 74.0, .site, "communauté du site")] {
            var summary = summary(for: host, services: UDPService.allCases, community: choice, ntpChecks: true)
            summary.date = now.addingTimeInterval(-minutes * 60)
            states[host] = UDPHostState(summary: summary, done: summary.results.count, total: summary.results.count, communityNote: note)
        }
        return states
    }

    /// Résultat fixe d'un hôte (le même à chaque clic), limité aux sondes cochées.
    static func summary(for host: String, services: [UDPService], community: UDPCommunityChoice, ntpChecks: Bool) -> UDPScanSummary {
        let all = results(for: host, community: community, ntpChecks: ntpChecks)
        let kept = all.filter { services.contains($0.service) }
        return UDPScanSummary(host: host, results: kept, duration: 1.2 + Double(kept.filter { $0.state == .openFiltered }.count) * 0.6)
    }

    nonisolated private static func closed(_ service: UDPService) -> UDPProbeResult {
        UDPProbeResult(service: service, state: .closed)
    }

    nonisolated private static func silent(_ service: UDPService) -> UDPProbeResult {
        UDPProbeResult(service: service, state: .openFiltered)
    }

    nonisolated private static func fill(_ open: [UDPProbeResult], rest: (UDPService) -> UDPProbeResult = closed) -> [UDPProbeResult] {
        UDPService.allCases.map { service in open.first { $0.service == service } ?? rest(service) }
    }

    static func results(for host: String, community: UDPCommunityChoice, ntpChecks: Bool) -> [UDPProbeResult] {
        switch host {
        case printer:
            return fill([
                UDPProbeResult(service: .netbios, state: .open, rttMs: 2.8, summary: "NetBIOS · BRN94DDF818157D · groupe WORKGROUP",
                               details: ["BRN94DDF818157D <00>", "WORKGROUP <00> (groupe)", "Adresse MAC annoncée\u{00A0}: 94:DD:F8:18:15:7D"]),
                printerSNMP(community),
                UDPProbeResult(service: .mdns, state: .open, rttMs: 4.1,
                               summary: "mDNS · 6 services\u{00A0}: ipp, ipps, printer, pdl-datastream, uscan…",
                               details: ["_ipp._tcp.local.", "_ipps._tcp.local.", "_printer._tcp.local.", "_pdl-datastream._tcp.local.",
                                         "_uscan._tcp.local.", "_http._tcp.local."]),
            ], rest: { $0 == .ssdp ? silent($0) : closed($0) })
        case phone:
            return fill([
                UDPProbeResult(service: .sip, state: .open, rttMs: 6.3, summary: "SIP 200 OK · Yealink SIP-T54W 96.86.0.70",
                               details: ["Réponse à OPTIONS\u{00A0}: 200 OK",
                                         "Méthodes\u{00A0}: INVITE, INFO, PRACK, ACK, BYE, CANCEL, OPTIONS, NOTIFY, REGISTER, SUBSCRIBE, REFER, PUBLISH, UPDATE, MESSAGE"],
                               findings: [.sipExposed]),
            ], rest: { $0 == .snmp ? silent($0) : closed($0) })
        case controller:
            return fill([
                UDPProbeResult(service: .dns, state: .open, rttMs: 0.9, summary: "Résolveur DNS (récursif)",
                               details: ["version.bind\u{00A0}: REFUSED (version masquée)", "A localhost\u{00A0}: NOERROR, récursion disponible"]),
                UDPProbeResult(service: .ntp, state: .open, rttMs: 1.1, summary: "NTPv3 · strate 3 · réf. 10.182.122.1",
                               details: ["Strate 3, source de référence 10.182.122.1."]),
                UDPProbeResult(service: .netbios, state: .open, rttMs: 1.3, summary: "NetBIOS · SRV-AD-01 · groupe BUREAU",
                               details: ["SRV-AD-01 <00>", "BUREAU <00> (groupe)", "BUREAU <1C> (groupe)", "SRV-AD-01 <20>",
                                         "Adresse MAC annoncée\u{00A0}: F4:EE:08:3C:72:A1"]),
            ], rest: { $0 == .snmp ? silent($0) : closed($0) })
        case gateway:
            var snmp = UDPProbeResult(service: .snmp, state: .open, rttMs: 1.6, summary: "SNMP v3 · moteur Fortinet",
                                      details: ["engineID\u{00A0}: 800030440446475436304654323231303032", "Redémarrages du moteur\u{00A0}: 12 · en marche depuis 41\u{00A0}j 6\u{00A0}h"])
            if community == .site {
                snmp.summary = "SNMP v2c · FortiGate-60F v7.2.8,build1639,240313 (GA.M)"
                snmp.details.insert("SNMP v3 · moteur Fortinet", at: 0)
                snmp.findings = [.snmpV2c]
            }
            return fill([
                UDPProbeResult(service: .dns, state: .open, rttMs: 0.7, summary: "Résolveur DNS (récursif)",
                               details: ["version.bind\u{00A0}: REFUSED (version masquée)", "A localhost\u{00A0}: NOERROR, récursion disponible"]),
                UDPProbeResult(service: .ntp, state: .open, rttMs: 0.8, summary: "NTPv4 · strate 2 · réf. 206.108.0.131",
                               details: ["Strate 2, source de référence 206.108.0.131."]),
                snmp,
            ], rest: silent)
        default:
            return generic(host, community: community)
        }
    }

    private static func printerSNMP(_ community: UDPCommunityChoice) -> UDPProbeResult {
        let v3 = "SNMP v3 · moteur Brother"
        let engine = "engineID\u{00A0}: 80000983030094ddf818157d"
        guard community == .publique else {
            return UDPProbeResult(service: .snmp, state: .open, rttMs: 3.4, summary: v3,
                                  details: [engine] + (community == .site ? ["Aucune réponse en v2c avec la communauté choisie."] : []))
        }
        return UDPProbeResult(service: .snmp, state: .open, rttMs: 3.4,
                              summary: "SNMP v2c · Brother NC-8300h, Firmware Ver.1.12 ,MID 8CE-K2F,FID 2",
                              details: [v3, "sysDescr\u{00A0}: Brother NC-8300h, Firmware Ver.1.12 ,MID 8CE-K2F,FID 2", engine],
                              findings: [.snmpPublic])
    }

    /// Autres appareils : d'après le type et le fabricant connus de la démonstration.
    private static func generic(_ host: String, community: UDPCommunityChoice) -> [UDPProbeResult] {
        let devices = DemoData.devices()
        guard let device = devices.first(where: { $0.ip.description == host }) else {
            return fill([], rest: silent)
        }
        let name = (device.hostname ?? device.displayName).uppercased()
        switch device.deviceType {
        case .imprimante:
            return fill([
                UDPProbeResult(service: .snmp, state: .open, rttMs: 5.0,
                               summary: community == .publique ? "SNMP v2c · HP ETHERNET MULTI-ENVIRONMENT" : "SNMP v3 · moteur HP",
                               findings: community == .publique ? [.snmpPublic] : []),
                UDPProbeResult(service: .mdns, state: .open, rttMs: 6.2, summary: "mDNS · 3 services\u{00A0}: ipp, printer, http"),
            ], rest: { $0 == .ssdp ? silent($0) : closed($0) })
        case .telephoneIP:
            return fill([
                UDPProbeResult(service: .sip, state: .open, rttMs: 6.8, summary: "SIP 200 OK · Yealink \(device.hostname ?? "SIP") 96.86.0.70",
                               findings: [.sipExposed]),
            ], rest: { $0 == .snmp ? silent($0) : closed($0) })
        case .poste:
            if device.vendor == "Apple" {
                return fill([UDPProbeResult(service: .mdns, state: .open, rttMs: 0.4, summary: "mDNS · 3 services\u{00A0}: ssh, sftp-ssh, rfb")],
                            rest: silent)
            }
            return fill([
                UDPProbeResult(service: .netbios, state: .open, rttMs: 1.8, summary: "NetBIOS · \(name) · groupe BUREAU"),
                UDPProbeResult(service: .ssdp, state: .open, rttMs: 2.4, summary: "UPnP · Microsoft-Windows/10.0 UPnP/1.0 UPnP-Device-Host/1.0"),
            ], rest: silent)
        case .serveur:
            var open = [UDPProbeResult(service: .netbios, state: .open, rttMs: 1.2, summary: "NetBIOS · \(name) · groupe BUREAU")]
            if device.vendor == "Synology" {
                open.append(UDPProbeResult(service: .ssdp, state: .open, rttMs: 1.9, summary: "UPnP · Synology/DSM/\(host)"))
                open.append(UDPProbeResult(service: .mdns, state: .open, rttMs: 1.5, summary: "mDNS · 4 services\u{00A0}: smb, afpovertcp, http, adisk"))
            }
            return fill(open, rest: { $0 == .snmp ? silent($0) : closed($0) })
        case .switch, .routeur, .pointAcces:
            return fill([UDPProbeResult(service: .snmp, state: .open, rttMs: 1.4,
                                        summary: community == .site ? "SNMP v2c · \(device.hostname ?? "équipement réseau")" : "SNMP v3",
                                        findings: community == .site ? [.snmpV2c] : [])], rest: silent)
        default:
            return fill([UDPProbeResult(service: .mdns, state: .open, rttMs: 3.2, summary: "mDNS · répond (aucun service annoncé)")],
                        rest: silent)
        }
    }
}
