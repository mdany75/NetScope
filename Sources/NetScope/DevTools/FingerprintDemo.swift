import Foundation
import NetScopeCore

/// Note 68 : indices d'empreinte des appareils de démonstration, comme un scan (TTL des réponses au
/// ping), la découverte SNMP (sysDescr) et des scans de ports avec détection de services les
/// auraient lus : bannières, en-têtes HTTP, certificats, négociation SMB, TXT mDNS. Aucun réseau.
enum FingerprintDemo {
    private static let seen = Date(timeIntervalSince1970: 1_793_000_000)

    private static func tls(_ port: UInt16, cn: String, o: String? = nil, ou: String? = nil, issuer: FPCertName? = nil,
                            server: String? = nil, status: String? = nil, title: String? = nil) -> FPServiceObservation {
        let subject = FPCertName(commonName: cn, organization: o, organizationalUnit: ou)
        return FPServiceObservation(port: port, httpStatus: status, httpServer: server, httpTitle: title, tls: true,
                                    certSubject: subject, certIssuer: issuer ?? subject, certSelfSigned: issuer == nil,
                                    certNotAfter: seen.addingTimeInterval(400 * 86_400), observedAt: seen)
    }

    private static func http(_ port: UInt16, _ status: String, server: String? = nil, powered: String? = nil,
                             title: String? = nil) -> FPServiceObservation {
        FPServiceObservation(port: port, httpStatus: status, httpServer: server, httpPoweredBy: powered, httpTitle: title,
                             observedAt: seen)
    }

    private static func banner(_ port: UInt16, _ text: String) -> FPServiceObservation {
        FPServiceObservation(port: port, banner: text, observedAt: seen)
    }

    private static func smb(_ dialect: UInt16, samba: Bool, signing: Bool) -> FPServiceObservation {
        FPServiceObservation(port: 445, smbDialect: dialect, smbSigningRequired: signing, smbSambaHint: samba, observedAt: seen)
    }

    /// Indices par adresse IP (appareils de DemoData).
    static let evidence: [String: FPEvidence] = [
        "10.182.122.1": FPEvidence(services: [
            tls(443, cn: "FGT60FTK2109ABCD", o: "Fortinet", ou: "FortiGate", server: "xxxxxxxx-xxxxx", status: "HTTP/1.1 200 OK"),
        ], sysDescr: "FortiGate-60F v7.2.8,build1639,240313 (GA.M)", ttl: 255),
        "10.182.122.2": FPEvidence(services: [
            banner(22, "SSH-2.0-Cisco-1.25"),
            banner(23, "User Access Verification"),
            tls(443, cn: "IOS-Self-Signed-Certificate-3058292817", status: "HTTP/1.1 200 OK"),
        ], sysDescr: "Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)",
           ttl: 255),
        "10.182.122.3": FPEvidence(services: [
            banner(22, "SSH-2.0-OpenSSH_8.3"),
            http(80, "HTTP/1.1 200 OK", title: "Aruba 2930F-24G-PoE+-4SFP+"),
        ], sysDescr: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012, ROM WC.16.01.0010", ttl: 64),
        "10.182.122.100": FPEvidence(ttl: 64),
        "10.182.122.102": FPEvidence(services: [
            tls(443, cn: "FAP231FTF21012345", o: "Fortinet", ou: "FortiAP"),
        ], ttl: 64),
        "10.182.122.106": FPEvidence(services: [
            http(80, "HTTP/1.1 200 OK", server: "lighttpd/1.4.59", title: "BrightSign® Diagnostic Web Server"),
        ], ttl: 64),
        "10.182.122.111": FPEvidence(services: [
            http(80, "HTTP/1.1 301 Moved Permanently", server: "debut/1.30"),
            tls(443, cn: "BRN94DDF818157D", o: "Brother Industries, Ltd.", server: "debut/1.30", status: "HTTP/1.1 200 OK",
                title: "Brother DCP-L2640DW series"),
        ], sysDescr: "Brother NC-8300w, Firmware Ver.1.07  (22.04.06),MID 8C5-K9F,FID 2",
           mdnsTXT: ["ty": "Brother DCP-L2640DW series", "product": "(Brother DCP-L2640DW series)"], ttl: 64),
        "10.182.122.113": FPEvidence(services: [smb(0x0311, samba: false, signing: false)], ttl: 128),
        "10.182.122.117": FPEvidence(services: [smb(0x0311, samba: false, signing: false)], ttl: 128),
        "10.182.122.121": FPEvidence(services: [
            http(80, "HTTP/1.1 301 Moved Permanently"),
            tls(443, cn: "SIP-T54W", o: "Yealink Network Technology Co., Ltd.", status: "HTTP/1.1 200 OK", title: "Yealink T54W"),
        ], ttl: 64),
        "10.182.122.122": FPEvidence(ttl: 64),
        "10.182.122.123": FPEvidence(ttl: 64),
        "10.182.122.126": FPEvidence(ttl: 128),
        "10.182.122.133": FPEvidence(ttl: 64),
        "10.182.122.135": FPEvidence(services: [
            banner(22, "SSH-2.0-OpenSSH_9.8"),
            banner(5900, "RFB 003.889"),
        ], mdnsTXT: ["model": "Macmini9,1", "osxvers": "24"], ttl: 64),
        "10.182.122.140": FPEvidence(services: [
            http(80, "HTTP/1.1 200 OK", server: "HP HTTP Server; HP LaserJet Pro M404dn - W1A53A; Serial Number: PHBQB12345; Built:Mon Jun 17, 2019 04:12:35PM {002_1922A}"),
        ], sysDescr: "HP ETHERNET MULTI-ENVIRONMENT,SN:PHBQB12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn", ttl: 255),
        "10.182.122.154": FPEvidence(services: [
            http(80, "HTTP/1.1 302 Found", server: "nginx"),
            tls(443, cn: "synology", o: "Synology Inc.", issuer: FPCertName(commonName: "Synology Inc. CA", organization: "Synology Inc."),
                server: "nginx", status: "HTTP/1.1 200 OK", title: "DS920-B01 - Synology DiskStation"),
            smb(0x0311, samba: true, signing: false),
            http(5000, "HTTP/1.1 200 OK", server: "nginx", title: "DS920-B01 - Synology DiskStation"),
        ], mdnsTXT: ["vendor": "Synology", "model": "DS920+", "version_major": "7", "version_minor": "2", "version_build": "72806"],
           ttl: 64),
        "192.168.50.21": FPEvidence(services: [
            http(80, "HTTP/1.1 200 OK", server: "App-webs/"),
            tls(443, cn: "192.168.50.21", o: "Hikvision", server: "App-webs/", status: "HTTP/1.1 200 OK"),
        ], ttl: 64),
        "192.168.50.22": FPEvidence(services: [
            http(80, "HTTP/1.1 302 Found", server: "Apache/2.4.58"),
            tls(443, cn: "axis-b8a44f2c19e0", o: "Axis Communications AB", server: "Apache/2.4.58", status: "HTTP/1.1 200 OK",
                title: "AXIS M3106-L Mk II"),
        ], ttl: 64),
        "10.10.0.10": FPEvidence(services: [smb(0x0311, samba: false, signing: true)], ttl: 128),
        "10.10.0.20": FPEvidence(services: [
            banner(22, "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"),
        ], ttl: 64),
        "10.10.0.31": FPEvidence(services: [
            banner(22, "SSH-2.0-OpenSSH_8.4p1 Debian-5+deb11u3"),
            tls(443, cn: "srv-backup.bureau.local", server: "nginx/1.18.0", status: "HTTP/1.1 200 OK", title: "Proxmox Backup Server"),
            smb(0x0311, samba: true, signing: false),
        ], ttl: 64),
        "192.168.50.31": FPEvidence(services: [
            http(80, "HTTP/1.1 200 OK", server: "DNVRS-Webs"),
        ], ttl: 64),
    ]
}
