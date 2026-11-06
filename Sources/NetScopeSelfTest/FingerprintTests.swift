import Darwin
import Foundation
import NetScopeCore

// Note 68 : empreinte légère des services et du système. Réponses recopiées (bannières, en-têtes,
// certificats DER, négociation SMB2) : aucun réseau, sauf un serveur local sur 127.0.0.1.

/// Certificat auto-signé de type FortiGate (O=Fortinet, OU=FortiGate, CN=numéro de série), DER.
private let fortigateCertificate = "MIICXTCCAgSgAwIBAgICMDkwCgYIKoZIzj0EAwIwgZ0xCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlTdW5ueXZhbGUxETAPBgNVBAoMCEZvcnRpbmV0MRIwEAYDVQQLDAlGb3J0aUdhdGUxGTAXBgNVBAMMEEZHVDYwRlRLMjEwOUFCQ0QxIzAhBgkqhkiG9w0BCQEWFHN1cHBvcnRAZm9ydGluZXQuY29tMB4XDTI2MTEwNjAwMTczN1oXDTM2MTEwMzAwMTczN1owgZ0xCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlTdW5ueXZhbGUxETAPBgNVBAoMCEZvcnRpbmV0MRIwEAYDVQQLDAlGb3J0aUdhdGUxGTAXBgNVBAMMEEZHVDYwRlRLMjEwOUFCQ0QxIzAhBgkqhkiG9w0BCQEWFHN1cHBvcnRAZm9ydGluZXQuY29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7gPfRO7aKTsFXjGF9bloHrItDQJN/Qna6lv+xF9KO0INRsrvIaay4n2WzShdz6i3e4nSObIP69tlEjgoD6dBraMyMDAwHQYDVR0OBBYEFKDrIqqcMb103V2Bft7o56cDgJ0BMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgHua5o+scfThUx/ohTnYLN6gBdVZOVcDnuWFhjeyTWLoCIEpMzu3l+/iGq7A176Jw8ueEoflIisiW3tuJGpKgZbHV"

/// Certificat d'un NAS Synology signé par l'autorité de Synology (émetteur différent du sujet), DER.
private let synologyCertificate = "MIIBujCCAWCgAwIBAgIBBzAKBggqhkjOPQQDAjBAMQswCQYDVQQGEwJUVzEWMBQGA1UECgwNU3lub2xvZ3kgSW5jLjEZMBcGA1UEAwwQU3lub2xvZ3kgSW5jLiBDQTAeFw0yNjExMDYwMDE3NDJaFw0yOTAyMDgwMDE3NDJaMEkxCzAJBgNVBAYTAlRXMQ8wDQYDVQQHDAZUYWlwZWkxFjAUBgNVBAoMDVN5bm9sb2d5IEluYy4xETAPBgNVBAMMCHN5bm9sb2d5MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzzj5FPxH845cMmq04bfKFcuTsIN1TAzcoUMafgnyGv89K5LQaV8+Fh7mTefBlBPEssyOfRHFv1G8Ke7cvBqFyaNCMEAwHQYDVR0OBBYEFNborZzwnZ81k+NUJdUcp4dizxWJMB8GA1UdIwQYMBaAFKswykNOY45JF0mSVK1tKDYVynBKMAoGCCqGSM49BAMCA0gAMEUCIAEo/xIiEvfMAGiELaaQTR2nxLvcIEAFcOtHRH4dP+ebAiEAnS6ILETET1BQlhxIZt3IlP52FDxafkmjfZ3JC413mFU="

/// Réponse NEGOTIATE SMB2 construite comme celle d'un serveur (dialecte, mode de sécurité, SPNEGO).
private func smbNegotiateResponse(dialect: UInt16, signingRequired: Bool, spnego: [UInt8]) -> Data {
    func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    var smb: [UInt8] = [0xFE, 0x53, 0x4D, 0x42] + le16(64) + le16(0) + [0, 0, 0, 0] + le16(0) + le16(1)
    smb += [1, 0, 0, 0] + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [0xFF, 0xFE, 0, 0] + [0, 0, 0, 0]
    smb += [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0, count: 16)
    smb += le16(65) + le16(signingRequired ? 0x03 : 0x01) + le16(dialect) + le16(0)
    smb += [UInt8](repeating: 0xAB, count: 16)          // ServerGuid
    smb += [0x7F, 0, 0, 0] + [0, 0, 0x80, 0] + [0, 0, 0x80, 0] + [0, 0, 0x80, 0]
    smb += [UInt8](repeating: 0x11, count: 8) + [UInt8](repeating: 0, count: 8)
    smb += le16(128) + le16(UInt16(spnego.count)) + [0, 0, 0, 0]
    smb += spnego
    let length = smb.count
    return Data([0x00, UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + smb)
}

/// Valeur présente, sinon échec du test.
private func require<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — absent", file: file, line: line) }
    return value
}

func registerFingerprintTests(_ suite: TestSuite) {
    suite.add("Empreinte : bannières SSH (Ubuntu, Debian, Windows, Dropbear, MikroTik)") {
        let ubuntu = FPServiceRules.analyze(FPServiceObservation(port: 22, banner: "SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6"))
        try expectEqual(ubuntu.productLabel, "OpenSSH 8.9p1", "produit et version")
        try expectEqual(ubuntu.system, "Ubuntu", "système trahi")
        let report = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 22, banner: "SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6")], ttl: 63))
        try expectEqual(report.system?.label, "Ubuntu 22.04", "Ubuntu 22.04 d'après le paquet")
        try expectEqual(report.system?.confidence, .forte, "confiance forte")
        try expect(report.system?.clues.contains { $0.source == .ttl } == true, "TTL 63 → 64 cohérent")

        let debian = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 22, banner: "SSH-2.0-OpenSSH_8.4p1 Debian-5+deb11u3")]))
        try expectEqual(debian.system?.label, "Debian 11", "Debian 11")
        let windows = FPServiceRules.analyze(FPServiceObservation(port: 22, banner: "SSH-2.0-OpenSSH_for_Windows_8.1"))
        try expectEqual(windows.productLabel, "OpenSSH pour Windows 8.1", "OpenSSH de Windows")
        try expectEqual(windows.system, "Windows", "Windows")
        let dropbear = FPServiceRules.analyze(FPServiceObservation(port: 22, banner: "SSH-2.0-dropbear_2020.81"))
        try expectEqual(dropbear.productLabel, "Dropbear 2020.81", "Dropbear")
        let mikrotik = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 22, banner: "SSH-2.0-ROSSSH")]))
        try expectEqual(mikrotik.system?.name, "MikroTik RouterOS", "RouterOS")
        try expectEqual(mikrotik.strongType, .routeur, "routeur (indice fort)")
    }

    suite.add("Empreinte : en-têtes HTTP (IIS, Apache, FortiGate, imprimantes)") {
        let iis = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 80, httpStatus: "HTTP/1.1 200 OK",
                                                                                   httpServer: "Microsoft-IIS/10.0",
                                                                                   httpPoweredBy: "ASP.NET")]))
        try expectEqual(iis.service(80)?.productLabel, "Microsoft IIS 10.0", "IIS 10")
        try expectEqual(iis.system?.name, "Windows", "Windows")
        try expectEqual(iis.system?.version, "10 / Server 2016 ou plus récent", "version de Windows d'après IIS")
        try expectEqual(iis.service(80)?.clearText, "HTTP", "page servie sans TLS")

        let apache = FPServiceRules.analyze(FPServiceObservation(port: 80, httpStatus: "HTTP/1.1 301 Moved Permanently",
                                                                 httpServer: "Apache/2.4.41 (Ubuntu)"))
        try expectEqual(apache.productLabel, "Apache httpd 2.4.41", "Apache")
        try expectEqual(apache.system, "Ubuntu", "Ubuntu entre parenthèses")
        try expect(apache.clearText == nil, "redirection vers HTTPS : pas un service en clair")

        let forti = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 443, httpStatus: "HTTP/1.1 200 OK",
                                                                                     httpServer: "xxxxxxxx-xxxxx", tls: true)]))
        try expectEqual(forti.system?.name, "FortiGate", "en-tête masqué de FortiOS")
        try expectEqual(forti.strongType, .routeur, "routeur / pare-feu")
        try expect(forti.service(443)?.clearText == nil, "HTTPS : pas en clair")

        let hp = FPServiceRules.analyze(FPServiceObservation(port: 80, httpServer: "HP HTTP Server; HP Color LaserJet MFP M477fdw - CF379A; Serial Number: CNB8K1234"))
        try expectEqual(hp.system, "Imprimante HP", "imprimante HP")
        try expect(hp.clues.contains { $0.conclusion.contains("HP Color LaserJet MFP M477fdw") }, "modèle lu")
        let brother = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 80, httpServer: "debut/1.30",
                                                                                       httpTitle: "Brother DCP-L2640DW series")]))
        try expectEqual(brother.strongType, .imprimante, "Brother (serveur debut)")
    }

    suite.add("Empreinte : FTP, SMTP, Telnet, VNC, MySQL") {
        let vsftpd = FPServiceRules.analyze(FPServiceObservation(port: 21, banner: "220 (vsFTPd 3.0.3)"))
        try expectEqual(vsftpd.productLabel, "vsftpd 3.0.3", "vsftpd")
        try expectEqual(vsftpd.clearText, "FTP", "FTP en clair")
        let proftpd = FPServiceRules.analyze(FPServiceObservation(port: 21, banner: "220 ProFTPD 1.3.5e Server (Debian) [::ffff:10.0.0.5]"))
        try expectEqual(proftpd.productLabel, "ProFTPD 1.3.5e", "ProFTPD")
        let exchange = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 25,
            banner: "220 MAIL01.contoso.local Microsoft ESMTP MAIL Service ready at Tue, 4 Nov 2026 10:00:00 -0500 Version: 10.0.17763.1")]))
        try expectEqual(exchange.system?.version, "10 (1809) / Server 2019", "build 17763")
        try expectEqual(exchange.system?.deviceType, .serveur, "serveur")
        let postfix = FPServiceRules.analyze(FPServiceObservation(port: 25, banner: "220 mail.exemple.ca ESMTP Postfix (Ubuntu)"))
        try expectEqual(postfix.product, "Postfix", "Postfix")
        let telnet = FPServiceRules.analyze(FPServiceObservation(port: 23, banner: "User Access Verification"))
        try expectEqual(telnet.clearText, "Telnet", "Telnet en clair")
        try expectEqual(telnet.system, "Cisco IOS", "invite Cisco")
        let vnc = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 5900, banner: "RFB 003.889")]))
        try expectEqual(vnc.system?.name, "macOS", "partage d'écran macOS")
        let mysql = FPServiceRules.analyze(FPServiceObservation(port: 3306, banner: "5.7.33-0ubuntu0.18.04.1"))
        try expectEqual(mysql.productLabel, "MySQL 5.7.33", "MySQL")
    }

    suite.add("Empreinte : réponses brutes (HTTP, MySQL, Telnet)") {
        let raw = "HTTP/1.1 401 Unauthorized\r\nServer: Boa/0.94.14rc21\r\nX-Powered-By: PHP/7.4.3\r\nWWW-Authenticate: Basic realm=\"HP LaserJet M404\"\r\n\r\n<html><title>Accès</title></html>"
        let http = FPBanner.httpObservation(port: 8080, data: Data(raw.utf8))
        try expectEqual(http?.httpStatus, "HTTP/1.1 401 Unauthorized", "ligne d'état")
        try expectEqual(http?.httpServer, "Boa/0.94.14rc21", "Server")
        try expectEqual(http?.httpPoweredBy, "PHP/7.4.3", "X-Powered-By")
        try expectEqual(http?.httpRealm, "HP LaserJet M404", "realm")
        try expectEqual(http?.httpTitle, "Accès", "titre")
        try expect(FPBanner.httpObservation(port: 80, data: Data("SSH-2.0-x\r\n".utf8)) == nil, "pas du HTTP")
        // Accueil MySQL : longueur 3 octets, numéro, protocole 10, version, 0.
        var greeting: [UInt8] = [0x4A, 0, 0, 0, 0x0A]
        greeting += Array("10.6.12-MariaDB-0ubuntu0.22.04.1".utf8) + [0, 1, 2, 3]
        try expectEqual(FPBanner.listenObservation(port: 3306, data: Data(greeting))?.banner,
                        "10.6.12-MariaDB-0ubuntu0.22.04.1", "version MySQL/MariaDB")
        let mariadb = FPServiceRules.analyze(FPServiceObservation(port: 3306, banner: "10.6.12-MariaDB-0ubuntu0.22.04.1"))
        try expectEqual(mariadb.productLabel, "MariaDB 10.6.12", "MariaDB")
        let telnet: [UInt8] = [0xFF, 0xFB, 0x01, 0xFF, 0xFB, 0x03, 0x0D, 0x0A] + Array("MikroTik v6.49.10 (long-term)\r\nLogin: ".utf8)
        try expectEqual(FPBanner.listenObservation(port: 23, data: Data(telnet))?.banner, "MikroTik v6.49.10 (long-term)",
                        "négociation Telnet retirée")
    }

    suite.add("Empreinte : certificat TLS lu en DER (sujet, émetteur, fin, auto-signé)") {
        let forti = try require(FPCertificate.parse(der: Data(base64Encoded: fortigateCertificate)!), "certificat FortiGate lu")
        try expectEqual(forti.subject.commonName, "FGT60FTK2109ABCD", "CN")
        try expectEqual(forti.subject.organization, "Fortinet", "O")
        try expectEqual(forti.subject.organizationalUnit, "FortiGate", "OU")
        try expect(forti.isSelfSigned, "auto-signé")
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2036; components.month = 11; components.day = 3; components.hour = 0; components.minute = 17; components.second = 37
        try expectEqual(forti.notAfter, components.date, "fin de validité (UTCTime)")
        let synology = try require(FPCertificate.parse(der: Data(base64Encoded: synologyCertificate)!), "certificat Synology lu")
        try expectEqual(synology.subject.commonName, "synology", "CN")
        try expectEqual(synology.issuer.commonName, "Synology Inc. CA", "émetteur")
        try expect(!synology.isSelfSigned, "signé par une autorité")
        try expect(FPCertificate.parse(der: Data([0x30, 0x03, 0x02, 0x01])) == nil, "DER tronqué refusé")

        let report = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 443, tls: true, certSubject: forti.subject,
                                                                                      certIssuer: forti.issuer, certSelfSigned: true)]))
        try expectEqual(report.system?.name, "FortiGate", "FortiGate d'après le certificat")
        try expectEqual(report.system?.family, .fortios, "FortiOS")
        let ap = FPServiceRules.analyze(FPServiceObservation(port: 443, tls: true, certSubject: FPCertName(commonName: "FAP231FTF21012345", organization: "Fortinet")))
        try expectEqual(ap.system, "FortiAP", "FortiAP d'après le numéro de série")
    }

    suite.add("Empreinte : négociation SMB2 (requête, dialecte, signature, Samba, SMB1)") {
        let request = [UInt8](FPSMB.negotiateRequest())
        try expectEqual(Int(request[1]) << 16 | Int(request[2]) << 8 | Int(request[3]), request.count - 4, "longueur NetBIOS")
        try expectEqual(Array(request[4..<8]), [0xFE, 0x53, 0x4D, 0x42], "en-tête SMB2")
        try expectEqual(request[4 + 64], 36, "StructureSize du NEGOTIATE")
        try expectEqual(request[4 + 66], 5, "cinq dialectes")
        // Dialectes à l'octet 100 de SMB2 : 2.0.2, 2.1, 3.0, 3.0.2, 3.1.1.
        try expectEqual(Array(request[(4 + 100)..<(4 + 110)]), [0x02, 0x02, 0x10, 0x02, 0x00, 0x03, 0x02, 0x03, 0x11, 0x03], "liste")
        try expectEqual(request[4 + 64 + 28], 112, "contextes à l'offset 112 (aligné sur 8)")
        try expectEqual(request[4 + 112], 1, "contexte d'intégrité en premier")

        let spnegoSamba = Array("NEGOTIATE not_defined_in_RFC4178@please_ignore".utf8)
        let samba = try require(FPSMB.parseNegotiateResponse(smbNegotiateResponse(dialect: 0x0311, signingRequired: false, spnego: spnegoSamba)), "réponse lue")
        try expectEqual(samba.dialect, 0x0311, "SMB 3.1.1")
        try expectEqual(samba.signingRequired, false, "signature facultative")
        try expect(samba.sambaHint, "indice Samba")
        let windows = try require(FPSMB.parseNegotiateResponse(smbNegotiateResponse(dialect: 0x0302, signingRequired: true, spnego: [0x60, 0x28, 0x06, 0x06])), "Windows")
        try expectEqual(windows.signingRequired, true, "signature exigée (contrôleur de domaine)")
        try expect(!windows.sambaHint, "pas Samba")
        let windowsReport = Fingerprinter.analyze(FPEvidence(services: [FPSMB.observation(port: 445, windows)]), openPorts: [135, 445])
        try expectEqual(windowsReport.system?.name, "Windows", "Windows d'après SMB et les ports")
        try expectEqual(windowsReport.system?.version, "8.1 / Server 2012 R2", "SMB 3.0.2")
        try expectEqual(windowsReport.service(445)?.productLabel, "SMB 3.0.2", "dialecte affiché")
        let smb1 = try require(FPSMB.parseNegotiateResponse(Data([0x00, 0x00, 0x00, 0x23, 0xFF, 0x53, 0x4D, 0x42, 0x72] + [UInt8](repeating: 0, count: 30))), "SMB1")
        try expect(smb1.smb1Only, "SMB1 seulement")
        let smb1Result = FPServiceRules.analyze(FPSMB.observation(port: 445, smb1))
        try expectEqual(smb1Result.clearText, "SMB1", "SMB1 signalé")
        var error = [UInt8](smbNegotiateResponse(dialect: 0x0311, signingRequired: false, spnego: []))
        error[4 + 8] = 0x22; error[4 + 11] = 0xC0   // STATUS_ACCESS_DENIED
        try expect(FPSMB.parseNegotiateResponse(Data(error)) == nil, "réponse en erreur ignorée")
    }

    suite.add("Empreinte : sysDescr, TXT mDNS, TTL et décision du système") {
        let windows = Fingerprinter.analyze(FPEvidence(sysDescr: "Hardware: Intel64 Family 6 Model 85 Stepping 7 AT/AT COMPATIBLE - Software: Windows Version 6.3 (Build 17763 Multiprocessor Free)"))
        try expectEqual(windows.system?.label, "Windows 10 (1809) / Server 2019", "Windows d'après le build")
        let forti = Fingerprinter.analyze(FPEvidence(sysDescr: "FortiGate-60F v7.2.8,build1639,240313 (GA.M)"))
        try expectEqual(forti.strongType, .routeur, "FortiGate en SNMP")
        let hp = Fingerprinter.analyze(FPEvidence(sysDescr: "HP ETHERNET MULTI-ENVIRONMENT,SN:VNB3R12345,FN:4T2K0AB,SVCID:31254,PID:HP LaserJet Pro M404dn"))
        try expectEqual(hp.strongType, .imprimante, "imprimante HP en SNMP")

        let nas = Fingerprinter.analyze(FPEvidence(mdnsTXT: ["vendor": "Synology", "model": "DS920+", "version_major": "7",
                                                             "version_minor": "2", "version_build": "72806"], ttl: 64),
                                        openPorts: [139, 445, 5000, 5001], vendor: "Synology")
        try expectEqual(nas.system?.label, "Synology DSM 7.2 (build 72806)", "DSM d'après le TXT mDNS")
        try expectEqual(nas.strongType, .serveur, "NAS → serveur")
        let printer = Fingerprinter.analyze(FPEvidence(mdnsTXT: ["ty": "Brother DCP-L2640DW series"]))
        try expectEqual(printer.strongType, .imprimante, "ty → imprimante")

        let ttlOnly = Fingerprinter.analyze(FPEvidence(ttl: 127))
        try expectEqual(ttlOnly.system?.name, "Windows", "TTL 127 → 128")
        try expectEqual(ttlOnly.system?.confidence, .faible, "TTL seul : faible")
        try expect(ttlOnly.strongType == nil, "TTL seul : aucun type imposé")
        try expectEqual(FPSystemRules.initialTTL(250), 255, "TTL 255")
        let windowsPorts = Fingerprinter.analyze(FPEvidence(ttl: 128), openPorts: [135, 445, 3389])
        try expectEqual(windowsPorts.system?.confidence, .moyenne, "ports Windows + TTL 128 : moyenne")
        // Indices contraires : TTL 128 n'appuie pas Ubuntu, et la confiance tient grâce au paquet.
        let mixed = Fingerprinter.analyze(FPEvidence(services: [FPServiceObservation(port: 22, banner: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")], ttl: 128))
        try expectEqual(mixed.system?.label, "Ubuntu 24.04", "Ubuntu 24.04")
        try expect(mixed.system?.clues.contains { $0.source == .ttl } == false, "TTL incohérent écarté")
        let ttl = ICMPPinger.replyTTL([0x45, 0, 0, 84, 0, 0, 0, 0, 0x3F, 1, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2])
        try expectEqual(ttl, 63, "TTL lu dans l'en-tête IP")
        try expect(ICMPPinger.replyTTL([0, 0, 0, 0, 0, 0, 0, 0]) == nil, "sans en-tête IP")
    }

    suite.add("Empreinte : type amélioré si l'indice est fort, SNMP prioritaire, fusion des indices") {
        let cert = FPServiceObservation(port: 443, tls: true, certSubject: FPCertName(commonName: "FGT40F", organization: "Fortinet"))
        var device = Device(ip: IPv4Address("10.0.0.1")!, openPorts: [443], deviceType: .inconnu, fingerprint: FPEvidence(services: [cert]))
        try expectEqual(ScanDeviceClassifier.guess(device), .routeur, "FortiGate d'après le certificat")
        device.snmpKind = .switch
        try expectEqual(ScanDeviceClassifier.guess(device), .switch, "la découverte SNMP fait foi")
        let weak = Device(ip: IPv4Address("10.0.0.2")!, openPorts: [445, 135], fingerprint: FPEvidence(ttl: 128))
        try expectEqual(ScanDeviceClassifier.guess(weak), .poste, "indice faible : règles habituelles")

        var evidence = FPEvidence(services: [FPServiceObservation(port: 80, httpServer: "nginx")], ttl: 64)
        evidence.record(FPServiceObservation(port: 80, httpTitle: "Synology DiskStation"))
        evidence.record(FPServiceObservation(port: 22))
        try expectEqual(evidence.services.count, 1, "observation vide ignorée")
        try expectEqual(evidence.service(80)?.httpServer, "nginx", "champ gardé")
        try expectEqual(evidence.service(80)?.httpTitle, "Synology DiskStation", "champ ajouté")
        let merged = FPEvidence.merged(evidence, FPEvidence(ttl: 63))
        try expectEqual(merged?.ttl, 63, "TTL plus récent")
        try expectEqual(merged?.services.count, 1, "services gardés")
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(Device.self, from: data)
        try expectEqual(decoded.fingerprint, device.fingerprint, "empreinte enregistrée avec l'appareil")
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old["fingerprint"] = nil
        let legacy = try JSONDecoder().decode(Device.self, from: JSONSerialization.data(withJSONObject: old))
        try expect(legacy.fingerprint == nil, "fichier antérieur lu sans empreinte")
    }

    suite.add("Empreinte : rapport Sécurité (services en clair, versions annoncées)") {
        let telnet = Device(ip: IPv4Address("10.0.0.2")!, hostname: "SW-CORE-01", openPorts: [22, 23], deviceType: .switch,
                            fingerprint: FPEvidence(services: [FPServiceObservation(port: 22, banner: "SSH-2.0-Cisco-1.25"),
                                                               FPServiceObservation(port: 23, banner: "User Access Verification")]))
        let web = Device(ip: IPv4Address("10.0.0.20")!, hostname: "srv-web", openPorts: [80],
                         fingerprint: FPEvidence(services: [FPServiceObservation(port: 80, httpStatus: "HTTP/1.1 200 OK",
                                                                                 httpServer: "nginx/1.18.0 (Ubuntu)")]))
        let plain = Device(ip: IPv4Address("10.0.0.30")!, openPorts: [80])
        let findings = ReportBuilder.fingerprintFindings([web, telnet, plain])
        try expectEqual(findings.first?.detail, "Telnet", "Telnet en tête")
        try expectEqual(findings.first?.severity, .eleve, "Telnet : élevé")
        try expect(findings.contains { $0.kind == .version && $0.detail == "Cisco SSH 1.25" }, "version Cisco annoncée")
        try expect(findings.contains { $0.kind == .clearText && $0.detail == "HTTP (nginx 1.18.0)" && $0.severity == .faible },
                   "HTTP en clair sur un serveur : faible")
        try expect(!findings.contains { $0.ip == plain.ip }, "appareil sans service lu : rien")
        let document = ReportBuilder.build(config: ReportConfig(template: .securite), input: ReportInput(devices: [telnet, web]))
        let section = try require(document.sections.first { $0.kind == .securite }, "section Sécurité")
        try expect(section.blocks.contains { if case .table(let table) = $0 { return table.columns.contains { $0.title == "Constat" } }; return false },
                   "tableau des versions et services en clair")
    }

    suite.add("Empreinte : scan local (127.0.0.1), observation gardée avec le résultat") {
        let listener = try LocalTCPServer { fd in
            let banner = Array("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n".utf8)
            _ = send(fd, banner, banner.count, 0)
        }
        defer { listener.stop() }
        let options = PortScanOptions(timeout: 2, concurrency: 2, grabBanners: true, bannerTimeout: 2, extraListenPorts: [listener.port])
        let summary = await PortScanner.scan(host: "127.0.0.1", ports: [listener.port], options: options)
        let result = summary.results.first
        try expectEqual(result?.observation?.banner, "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5", "bannière observée")
        var device = Device(ip: IPv4Address("127.0.0.1")!, openPorts: [listener.port])
        device.recordServices(summary.results)
        try expectEqual(device.fingerprintReport.system?.label, "Ubuntu 24.04", "système déduit")
    }
}
