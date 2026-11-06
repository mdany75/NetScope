import Foundation

/// Voix d'un indice pour un système (agrégées par FPSystemRules).
struct FPVote: Hashable, Sendable {
    var family: FPSystemFamily
    /// Nom précis (« Windows Server », « Ubuntu », « FortiGate »).
    var name: String?
    var version: String?
    var type: DeviceType?
    var clue: FPClue
}

/// Règles d'un service : produit, version, système trahi, protocole en clair. Pures, sans réseau.
public enum FPServiceRules {
    public static func analyze(_ observation: FPServiceObservation) -> FPServiceResult {
        evaluate(observation).result
    }

    static func evaluate(_ observation: FPServiceObservation) -> (result: FPServiceResult, votes: [FPVote]) {
        var context = Context(port: observation.port)
        let port = observation.port
        if let banner = observation.banner?.trimmingCharacters(in: .whitespaces), !banner.isEmpty {
            if banner.hasPrefix("SSH-") {
                ssh(banner, &context)
            } else if banner.hasPrefix("RFB ") {
                vnc(banner, &context)
            } else if port == 3306 || banner.lowercased().contains("mariadb") && port != 21 {
                mysql(banner, &context)
            } else if port == 21 || port == 2121 || (banner.hasPrefix("220") && banner.lowercased().contains("ftp")) {
                ftp(banner, &context)
            } else if [25, 465, 587].contains(port) || banner.hasPrefix("220") && banner.uppercased().contains("SMTP") {
                smtp(banner, &context)
            } else if port == 110 || banner.hasPrefix("+OK") {
                context.result.product = context.result.product ?? "POP3"
                if !observation.tls { context.result.clearText = "POP3" }
            } else if port == 143 || banner.hasPrefix("* OK") {
                context.result.product = context.result.product ?? "IMAP"
                if !observation.tls { context.result.clearText = "IMAP" }
            } else if port == 23 {
                telnet(banner, &context)
            }
        }
        if port == 23 { context.result.clearText = "Telnet" }
        if observation.smbDialect != nil || observation.smb1Only == true {
            smb(observation, &context)
        }
        if let server = observation.httpServer { httpServer(server, &context) }
        if let powered = observation.httpPoweredBy { poweredBy(powered, &context) }
        for (text, source) in [(observation.httpTitle, FPSource.title), (observation.httpRealm, FPSource.http)] {
            if let text, !text.isEmpty { pageHint(text, source: source, &context) }
        }
        if observation.tls {
            certificate(subject: observation.certSubject, issuer: observation.certIssuer, &context)
        }
        // HTTP sans TLS qui sert une page (pas une simple redirection vers HTTPS).
        if !observation.tls, let status = observation.httpStatus, context.result.clearText == nil {
            let code = Int(status.split(separator: " ").dropFirst().first ?? "") ?? 0
            if !(300...399).contains(code) { context.result.clearText = "HTTP" }
        }
        context.finish()
        return (context.result, context.votes)
    }

    // MARK: Contexte

    struct Context {
        var result: FPServiceResult
        var votes: [FPVote] = []

        init(port: UInt16) {
            result = FPServiceResult(port: port)
        }

        /// Produit et version lus (le premier produit trouvé reste, les indices s'ajoutent).
        mutating func product(_ name: String, version: String?, clue: FPClue) {
            if result.product == nil {
                result.product = name
                result.version = version.flatMap { $0.isEmpty ? nil : $0 }
            } else if result.product == name, result.version == nil {
                result.version = version
            }
            add(clue)
        }

        mutating func add(_ clue: FPClue) {
            if !result.clues.contains(clue) { result.clues.append(clue) }
            result.confidence = max(result.confidence, clue.weight)
        }

        mutating func vote(_ family: FPSystemFamily, name: String? = nil, version: String? = nil,
                           type: DeviceType? = nil, clue: FPClue) {
            votes.append(FPVote(family: family, name: name, version: version, type: type, clue: clue))
            if result.system == nil { result.system = name ?? family.label }
            add(clue)
        }

        mutating func finish() {
            if result.product == nil, result.clues.isEmpty { result.confidence = .faible }
        }
    }

    // MARK: SSH

    /// « SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6 », « SSH-2.0-dropbear_2020.81 », « SSH-2.0-ROSSSH ».
    static func ssh(_ banner: String, _ context: inout Context) {
        let port = context.result.port
        let body = banner.split(separator: "-", maxSplits: 2).dropFirst(2).first.map(String.init) ?? ""
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        let software = parts.first ?? ""
        let comment = parts.count > 1 ? parts[1] : ""
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .ssh, observed: banner, conclusion: conclusion, weight: weight, port: port)
        }
        if banner.hasPrefix("SSH-1.") && !banner.hasPrefix("SSH-1.99") {
            context.add(clue("protocole SSH 1 (obsolète)", .moyenne))
        }
        let lower = software.lowercased()
        if lower.hasPrefix("openssh_for_windows") {
            let version = software.split(separator: "_").last.map(String.init)
            context.product("OpenSSH pour Windows", version: version, clue: clue("OpenSSH pour Windows", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .moyenne))
        } else if lower.hasPrefix("openssh_") {
            let version = String(software.dropFirst("OpenSSH_".count))
            context.product("OpenSSH", version: version, clue: clue("OpenSSH \(version)", .forte))
            opensshDistribution(comment: comment, version: version, banner: banner, &context)
        } else if lower.hasPrefix("dropbear") {
            let version = software.split(separator: "_").dropFirst().first.map(String.init)
            context.product("Dropbear", version: version, clue: clue("Dropbear (Linux embarqué)", .forte))
            context.vote(.embedded, name: "Linux embarqué", clue: clue("Linux embarqué", .moyenne))
        } else if lower == "rosssh" {
            context.product("MikroTik SSH", version: nil, clue: clue("MikroTik", .forte))
            context.vote(.routeros, name: "MikroTik RouterOS", type: .routeur, clue: clue("MikroTik RouterOS", .forte))
        } else if lower.hasPrefix("cisco-") {
            context.product("Cisco SSH", version: software.split(separator: "-").last.map(String.init),
                            clue: clue("Cisco", .forte))
            context.vote(.ciscoIOS, name: "Cisco IOS", clue: clue("Cisco IOS", .forte))
        } else if lower.hasPrefix("comware") {
            context.product("Comware SSH", version: software.split(separator: "-").last.map(String.init),
                            clue: clue("HPE Comware", .forte))
            context.vote(.network, name: "HPE Comware", type: .switch, clue: clue("HPE Comware (switch)", .forte))
        } else if lower.hasPrefix("huawei") {
            context.product("Huawei SSH", version: software.split(separator: "-").last.map(String.init), clue: clue("Huawei", .forte))
            context.vote(.network, name: "Huawei VRP", clue: clue("Huawei VRP", .moyenne))
        } else if lower.hasPrefix("mpssh") {
            context.product("mpSSH", version: software.split(separator: "_").last.map(String.init), clue: clue("HPE iLO", .forte))
            context.vote(.bmc, name: "HPE iLO", type: .serveur, clue: clue("HPE iLO", .forte))
        } else if lower.hasPrefix("romsshell") {
            context.product("RomSShell", version: software.split(separator: "_").last.map(String.init), clue: clue("Allegro RomSShell (embarqué)", .moyenne))
            context.vote(.embedded, name: "Système embarqué", clue: clue("système embarqué", .moyenne))
        } else if lower.hasPrefix("libssh") {
            context.product("libssh", version: software.split(separator: "_").last.map(String.init), clue: clue("libssh", .moyenne))
        } else if lower.hasPrefix("fortissh") {
            context.product("FortiSSH", version: nil, clue: clue("Fortinet", .forte))
            context.vote(.fortios, name: "FortiOS", clue: clue("FortiOS", .forte))
        } else if !software.isEmpty {
            let split = productVersion(software, separators: ["_", "-", "/"])
            context.product(split.name, version: split.version, clue: clue(split.name, .moyenne))
        }
    }

    /// Distribution trahie par le paquet OpenSSH (« Ubuntu-3ubuntu0.6 », « Debian-10+deb9u7 »).
    static func opensshDistribution(comment: String, version: String, banner: String, _ context: inout Context) {
        let port = context.result.port
        let lower = comment.lowercased()
        let base = String(version.prefix { $0.isNumber || $0 == "." })
        if lower.contains("ubuntu") {
            let releases = ["9.6": "24.04", "9.3": "23.10", "9.0": "22.10", "8.9": "22.04", "8.4": "21.04",
                            "8.2": "20.04", "7.6": "18.04", "7.2": "16.04", "6.6": "14.04"]
            let release = releases[base]
            context.vote(.linux, name: "Ubuntu", version: release,
                         clue: FPClue(source: .ssh, observed: banner, conclusion: "Ubuntu" + (release.map { " \($0)" } ?? ""),
                                      weight: .forte, port: port))
        } else if lower.contains("debian") {
            var release: String?
            // « +deb11u3 » : Debian 11.
            if let range = lower.range(of: "deb[0-9]+", options: .regularExpression) {
                release = String(lower[range].dropFirst(3))
            }
            context.vote(.linux, name: "Debian", version: release,
                         clue: FPClue(source: .ssh, observed: banner, conclusion: "Debian" + (release.map { " \($0)" } ?? ""),
                                      weight: .forte, port: port))
        } else if lower.contains("raspbian") {
            context.vote(.linux, name: "Raspberry Pi OS",
                         clue: FPClue(source: .ssh, observed: banner, conclusion: "Raspberry Pi OS", weight: .forte, port: port))
        } else if lower.contains("freebsd") {
            context.vote(.bsd, name: "FreeBSD",
                         clue: FPClue(source: .ssh, observed: banner, conclusion: "FreeBSD", weight: .forte, port: port))
        } else if version.contains("p") {
            // OpenSSH « portable » (Linux, macOS, BSD…) : seulement « Unix ».
            context.add(FPClue(source: .ssh, observed: banner, conclusion: "Unix (OpenSSH portable)", weight: .faible, port: port))
        }
    }

    // MARK: FTP, SMTP, Telnet, VNC, MySQL

    /// « 220 (vsFTPd 3.0.3) », « 220 ProFTPD 1.3.5e Server (Debian) », « 220 Microsoft FTP Service ».
    static func ftp(_ banner: String, _ context: inout Context) {
        let port = context.result.port
        context.result.clearText = "FTP"
        let lower = banner.lowercased()
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .ftp, observed: banner, conclusion: conclusion, weight: weight, port: port)
        }
        if let version = word(after: "vsftpd", in: banner) ?? (lower.contains("vsftpd") ? "" : nil) {
            context.product("vsftpd", version: version, clue: clue("vsftpd (Linux)", .forte))
            context.vote(.linux, name: "Linux", clue: clue("Linux", .moyenne))
        } else if lower.contains("nasftpd") || lower.contains("turbo station") {
            context.product("ProFTPD (QNAP)", version: word(after: "station", in: banner), clue: clue("QNAP", .forte))
            context.vote(.qts, name: "QNAP QTS", type: .serveur, clue: clue("NAS QNAP", .forte))
        } else if lower.contains("proftpd") {
            context.product("ProFTPD", version: word(after: "ProFTPD", in: banner), clue: clue("ProFTPD", .forte))
            if lower.contains("debian") { context.vote(.linux, name: "Debian", clue: clue("Debian", .moyenne)) }
            else if lower.contains("ubuntu") { context.vote(.linux, name: "Ubuntu", clue: clue("Ubuntu", .moyenne)) }
        } else if lower.contains("microsoft ftp") {
            context.product("Microsoft FTP (IIS)", version: nil, clue: clue("IIS FTP", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .forte))
        } else if lower.contains("filezilla") {
            context.product("FileZilla Server", version: word(after: "Server", in: banner), clue: clue("FileZilla Server", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .moyenne))
        } else if lower.contains("pure-ftpd") {
            context.product("Pure-FTPd", version: nil, clue: clue("Pure-FTPd (Unix)", .moyenne))
        } else if lower.contains("diskstation") || lower.contains("synology") {
            context.product("FTP Synology", version: nil, clue: clue("Synology DiskStation", .forte))
            context.vote(.dsm, name: "Synology DSM", type: .serveur, clue: clue("NAS Synology", .forte))
        } else if lower.contains("serv-u") {
            context.product("Serv-U", version: word(after: "Serv-U", in: banner), clue: clue("Serv-U (Windows)", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .moyenne))
        } else if lower.contains("brother") || lower.contains("jetdirect") || lower.contains("printer") {
            context.product("FTP d’imprimante", version: nil, clue: clue("imprimante", .moyenne))
            context.vote(.printer, name: "Imprimante", type: .imprimante, clue: clue("imprimante", .moyenne))
        } else {
            context.product("FTP", version: nil, clue: clue("serveur FTP", .faible))
        }
    }

    /// « 220 mail.example.com ESMTP Postfix (Ubuntu) », « … Microsoft ESMTP MAIL Service, Version: 10.0.17763.1 ».
    static func smtp(_ banner: String, _ context: inout Context) {
        let port = context.result.port
        let lower = banner.lowercased()
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .smtp, observed: banner, conclusion: conclusion, weight: weight, port: port)
        }
        if lower.contains("microsoft esmtp") || lower.contains("microsoft smtp") {
            let version = word(after: "Version:", in: banner)
            context.product("Microsoft SMTP (Exchange ou IIS)", version: version, clue: clue("Microsoft Exchange ou IIS SMTP", .forte))
            let build = version.flatMap { windowsBuild(fromVersion: $0) }
            let release = build.flatMap(windowsRelease)
            context.vote(.windows, name: "Windows", version: release, type: .serveur,
                         clue: clue("Windows" + (release.map { " \($0)" } ?? ""), .forte))
        } else if lower.contains("postfix") {
            context.product("Postfix", version: nil, clue: clue("Postfix (Unix)", .forte))
            if lower.contains("ubuntu") { context.vote(.linux, name: "Ubuntu", clue: clue("Ubuntu", .moyenne)) }
            else if lower.contains("debian") { context.vote(.linux, name: "Debian", clue: clue("Debian", .moyenne)) }
        } else if lower.contains("exim") {
            context.product("Exim", version: word(after: "Exim", in: banner), clue: clue("Exim (Unix)", .forte))
        } else if lower.contains("sendmail") {
            let version = word(after: "Sendmail", in: banner).map { String($0.split(separator: "/").first ?? Substring($0)) }
            context.product("Sendmail", version: version, clue: clue("Sendmail (Unix)", .forte))
        } else if lower.contains("hmailserver") {
            context.product("hMailServer", version: nil, clue: clue("hMailServer (Windows)", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .moyenne))
        } else if lower.contains("esmtp") || lower.contains("smtp") {
            context.product("SMTP", version: nil, clue: clue("serveur SMTP", .faible))
        }
    }

    static func telnet(_ banner: String, _ context: inout Context) {
        let port = context.result.port
        let lower = banner.lowercased()
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .telnet, observed: banner, conclusion: conclusion, weight: weight, port: port)
        }
        context.result.product = context.result.product ?? "Telnet"
        if lower.contains("user access verification") {
            context.vote(.ciscoIOS, name: "Cisco IOS", clue: clue("invite Cisco IOS", .moyenne))
        } else if lower.contains("mikrotik") {
            context.vote(.routeros, name: "MikroTik RouterOS", type: .routeur, clue: clue("MikroTik RouterOS", .forte))
        } else if lower.contains("fortigate") || lower.contains("fortiswitch") {
            context.vote(.fortios, name: "FortiOS", clue: clue("FortiOS", .forte))
        } else if lower.contains("procurve") || lower.contains("aruba") {
            context.vote(.arubaOS, name: "ArubaOS", type: .switch, clue: clue("switch HPE Aruba", .forte))
        }
    }

    /// « RFB 003.008 » : protocole VNC 3.8 (non chiffré).
    static func vnc(_ banner: String, _ context: inout Context) {
        let raw = banner.dropFirst(4).trimmingCharacters(in: .whitespaces)
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        let version = parts.count == 2 ? "\(parts[0]).\(parts[1])" : nil
        context.product("VNC (RFB)", version: version,
                        clue: FPClue(source: .banner, observed: banner, conclusion: "VNC", weight: .forte, port: context.result.port))
        context.result.clearText = "VNC"
        // RFB 3.889 : partage d'écran de macOS.
        if raw.hasPrefix("003.889") {
            context.vote(.macos, name: "macOS", type: .poste,
                         clue: FPClue(source: .banner, observed: banner, conclusion: "Partage d’écran de macOS", weight: .forte,
                                      port: context.result.port))
        }
    }

    /// Bannière MySQL déjà réduite à sa version (« 5.7.33-0ubuntu0.18.04.1 », « 10.6.12-MariaDB »).
    static func mysql(_ banner: String, _ context: inout Context) {
        let lower = banner.lowercased()
        let version = String(banner.prefix { $0.isNumber || $0 == "." })
        let clue = FPClue(source: .banner, observed: banner, conclusion: lower.contains("mariadb") ? "MariaDB" : "MySQL",
                          weight: .forte, port: context.result.port)
        context.product(lower.contains("mariadb") ? "MariaDB" : "MySQL", version: version.isEmpty ? nil : version, clue: clue)
        if lower.contains("ubuntu") {
            context.vote(.linux, name: "Ubuntu", clue: FPClue(source: .banner, observed: banner, conclusion: "Ubuntu",
                                                              weight: .moyenne, port: context.result.port))
        }
    }

    // MARK: SMB

    static func smb(_ observation: FPServiceObservation, _ context: inout Context) {
        let port = observation.port
        if observation.smb1Only == true {
            let clue = FPClue(source: .smb, observed: "SMB1 seulement", conclusion: "SMB1 (obsolète)", weight: .forte, port: port)
            context.product("SMB", version: "1", clue: clue)
            context.result.clearText = "SMB1"
            return
        }
        guard let dialect = observation.smbDialect else { return }
        let name = FPSMB.dialectLabel(dialect)
        let signing = observation.smbSigningRequired.map { $0 ? ", signature exigée" : ", signature facultative" } ?? ""
        context.product("SMB", version: String(name.dropFirst(4)),
                        clue: FPClue(source: .smb, observed: name + signing, conclusion: name, weight: .forte, port: port))
        if observation.smbSambaHint == true {
            context.result.product = "Samba (SMB)"
            context.vote(.linux, name: "Linux (Samba)",
                         clue: FPClue(source: .smb, observed: "indice SPNEGO de Samba", conclusion: "Samba (Linux, NAS)",
                                      weight: .moyenne, port: port))
        } else {
            let release: String?
            switch dialect {
            case 0x0311: release = "10 / Server 2016 ou plus récent"
            case 0x0302: release = "8.1 / Server 2012 R2"
            case 0x0300: release = "8 / Server 2012"
            case 0x0210: release = "7 / Server 2008 R2"
            case 0x0202: release = "Vista / Server 2008"
            default: release = nil
            }
            context.vote(.windows, name: "Windows", version: release,
                         clue: FPClue(source: .smb, observed: name + " sans indice Samba",
                                      conclusion: "probablement Windows" + (release.map { " \($0)" } ?? ""), weight: .faible, port: port))
        }
    }

    // MARK: HTTP

    /// En-tête Server : « Apache/2.4.41 (Ubuntu) », « Microsoft-IIS/10.0 », « xxxxxxxx-xxxxx » (FortiGate)…
    static func httpServer(_ server: String, _ context: inout Context) {
        let port = context.result.port
        let observed = "Server: \(server)"
        let lower = server.lowercased()
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .http, observed: observed, conclusion: conclusion, weight: weight, port: port)
        }
        let first = String(server.split(separator: " ").first ?? "")
        let split = productVersion(first, separators: ["/"])
        // Commentaire entre parenthèses : système (« (Ubuntu) », « (Win64) »).
        let comment = server.range(of: "(").flatMap { open in
            server.range(of: ")", range: open.upperBound..<server.endIndex).map { String(server[open.upperBound..<$0.lowerBound]) }
        }

        if server == "xxxxxxxx-xxxxx" {
            context.product("FortiOS (administration web)", version: nil, clue: clue("FortiGate (en-tête masqué de FortiOS)", .forte))
            context.vote(.fortios, name: "FortiGate", type: .routeur, clue: clue("FortiGate", .forte))
            return
        }
        if lower.hasPrefix("microsoft-iis/") {
            let version = split.version
            context.product("Microsoft IIS", version: version, clue: clue("IIS \(version ?? "")".trimmingCharacters(in: .whitespaces), .forte))
            let release = version.flatMap(iisRelease)
            context.vote(.windows, name: "Windows", version: release,
                         clue: clue("Windows" + (release.map { " \($0)" } ?? ""), .forte))
            return
        }
        if lower.hasPrefix("microsoft-httpapi") {
            context.product("Microsoft HTTPAPI", version: split.version, clue: clue("HTTP.sys de Windows (WinRM, WSUS…)", .forte))
            context.vote(.windows, name: "Windows", clue: clue("Windows", .forte))
            return
        }
        let embedded: [(String, String, FPSystemFamily, String, DeviceType?)] = [
            ("hikvision-webs", "Hikvision Webs", .camera, "Caméra Hikvision", .camera),
            ("app-webs", "Hikvision App-webs", .camera, "Caméra Hikvision", .camera),
            ("dnvrs-webs", "Hikvision DNVRS-Webs", .camera, "Enregistreur Hikvision", .camera),
            ("dvrdvs-webs", "Hikvision DVRDVS-Webs", .camera, "Enregistreur Hikvision", .camera),
            ("uc-httpd", "uc-httpd", .camera, "Caméra ou enregistreur (XiongMai)", .camera),
            ("hp http server", "HP HTTP Server", .printer, "Imprimante HP", .imprimante),
            ("hp-chaisoe", "HP ChaiSOE", .printer, "Imprimante HP", .imprimante),
            ("virata-emweb", "Virata EmWeb", .printer, "Imprimante HP", .imprimante),
            ("debut/", "debut", .printer, "Imprimante Brother", .imprimante),
            ("km-mfp-http", "KM-MFP-http", .printer, "Imprimante Kyocera", .imprimante),
            ("canon http server", "Canon HTTP Server", .printer, "Imprimante Canon", .imprimante),
            ("epson", "EPSON HTTP", .printer, "Imprimante Epson", .imprimante),
            ("xerox_microserver", "Xerox MicroServer", .printer, "Imprimante Xerox", .imprimante),
            ("lexmark", "Lexmark Web Server", .printer, "Imprimante Lexmark", .imprimante),
            ("hpe-ilo-server", "HPE iLO", .bmc, "HPE iLO", .serveur),
            ("pve-api-daemon", "Proxmox VE", .linux, "Proxmox VE", .serveur),
            ("sonicwall", "SonicWall", .network, "Pare-feu SonicWall", .routeur),
            ("cisco-ios", "Cisco IOS HTTP", .ciscoIOS, "Cisco IOS", nil),
            ("mikrotik", "MikroTik HTTP", .routeros, "MikroTik RouterOS", .routeur),
        ]
        if let match = embedded.first(where: { lower.hasPrefix($0.0) || lower.contains($0.0) }) {
            context.product(match.1, version: split.version, clue: clue(match.3, .forte))
            context.vote(match.2, name: match.3, type: match.4, clue: clue(match.3, .forte))
            // « HP HTTP Server; HP Color LaserJet MFP M477fdw » : modèle après le point-virgule.
            if match.2 == .printer, let model = server.split(separator: ";").dropFirst().first {
                context.add(clue("modèle " + model.trimmingCharacters(in: .whitespaces), .forte))
            }
            return
        }
        let generic: [(String, String, String)] = [
            ("apache", "Apache httpd", "Apache httpd"), ("nginx", "nginx", "nginx"), ("lighttpd", "lighttpd", "lighttpd"),
            ("openresty", "OpenResty", "OpenResty"), ("caddy", "Caddy", "Caddy"), ("jetty", "Jetty", "Jetty (Java)"),
            ("kestrel", "Kestrel", "ASP.NET Core"), ("boa", "Boa", "Boa (embarqué)"), ("goahead", "GoAhead", "GoAhead (embarqué)"),
            ("mini_httpd", "mini_httpd", "mini_httpd (embarqué)"), ("thttpd", "thttpd", "thttpd (embarqué)"),
            ("rompager", "RomPager", "Allegro RomPager (embarqué)"), ("allegro", "RomPager", "Allegro RomPager (embarqué)"),
            ("mbedthis-appweb", "Appweb", "Appweb (embarqué)"), ("embedthis", "Appweb", "Appweb (embarqué)"),
            ("cherrypy", "CherryPy", "CherryPy (Python)"), ("werkzeug", "Werkzeug", "Werkzeug (Python)"),
            ("tornado", "Tornado", "Tornado (Python)"), ("gunicorn", "Gunicorn", "Gunicorn (Python)"),
        ]
        if let match = generic.first(where: { lower.hasPrefix($0.0) }) {
            // Jetty(9.4.z) : version entre parenthèses.
            var version = split.version
            if version == nil, match.0 == "jetty", let comment { version = comment }
            context.product(match.1, version: version, clue: clue(match.2 + (version.map { " \($0)" } ?? ""), .forte))
            if ["boa", "goahead", "mini_httpd", "thttpd", "rompager", "allegro", "mbedthis-appweb", "embedthis"].contains(match.0) {
                context.vote(.embedded, name: "Système embarqué", clue: clue("système embarqué", .moyenne))
            }
        } else if !first.isEmpty {
            context.product(split.name, version: split.version, clue: clue(split.name, .faible))
        }
        if let comment { serverComment(comment, observed: observed, &context) }
    }

    /// « (Ubuntu) », « (Debian) », « (CentOS) », « (Red Hat Enterprise Linux) », « (Win64) ».
    static func serverComment(_ comment: String, observed: String, _ context: inout Context) {
        let port = context.result.port
        let lower = comment.lowercased()
        let distributions: [(String, String)] = [("ubuntu", "Ubuntu"), ("debian", "Debian"), ("centos", "CentOS"),
                                                 ("red hat", "Red Hat Enterprise Linux"), ("rocky", "Rocky Linux"),
                                                 ("almalinux", "AlmaLinux"), ("fedora", "Fedora"), ("raspbian", "Raspberry Pi OS")]
        if let match = distributions.first(where: { lower.contains($0.0) }) {
            context.vote(.linux, name: match.1, clue: FPClue(source: .http, observed: observed, conclusion: match.1,
                                                             weight: .forte, port: port))
        } else if lower.hasPrefix("win") {
            context.vote(.windows, name: "Windows", clue: FPClue(source: .http, observed: observed, conclusion: "Windows",
                                                                 weight: .forte, port: port))
        } else if lower.contains("freebsd") {
            context.vote(.bsd, name: "FreeBSD", clue: FPClue(source: .http, observed: observed, conclusion: "FreeBSD",
                                                             weight: .forte, port: port))
        } else if lower == "unix" {
            context.add(FPClue(source: .http, observed: observed, conclusion: "Unix", weight: .faible, port: port))
        }
    }

    /// X-Powered-By : « PHP/7.4.3 », « ASP.NET », « Express ».
    static func poweredBy(_ value: String, _ context: inout Context) {
        let port = context.result.port
        let observed = "X-Powered-By: \(value)"
        let lower = value.lowercased()
        let split = productVersion(String(value.split(separator: " ").first ?? ""), separators: ["/"])
        if lower.hasPrefix("asp.net") {
            context.add(FPClue(source: .http, observed: observed, conclusion: "ASP.NET", weight: .moyenne, port: port))
            context.vote(.windows, name: "Windows", clue: FPClue(source: .http, observed: observed, conclusion: "Windows (ASP.NET)",
                                                                 weight: .moyenne, port: port))
        } else {
            let label = lower.hasPrefix("express") ? "Express (Node.js)" : split.name + (split.version.map { " \($0)" } ?? "")
            context.add(FPClue(source: .http, observed: observed, conclusion: label, weight: .moyenne, port: port))
            // La version de PHP compte comme version annoncée quand le serveur ne la donne pas.
            if context.result.product == nil {
                context.result.product = split.name
                context.result.version = split.version
            }
        }
    }

    /// Titre de page ou domaine d'authentification HTTP : « FortiGate », « Synology DiskStation »…
    static func pageHint(_ text: String, source: FPSource, _ context: inout Context) {
        let port = context.result.port
        let lower = text.lowercased()
        let observed = source == .title ? "«\u{00A0}\(text)\u{00A0}»" : "realm «\u{00A0}\(text)\u{00A0}»"
        let rules: [(String, FPSystemFamily, String, DeviceType?)] = [
            ("fortigate", .fortios, "FortiGate", .routeur), ("fortiwifi", .fortios, "FortiWiFi", .routeur),
            ("fortiap", .fortios, "FortiAP", .pointAcces), ("fortiswitch", .fortios, "FortiSwitch", .switch),
            ("synology router", .dsm, "Synology SRM", .routeur),
            ("synology", .dsm, "Synology DSM", .serveur), ("diskstation", .dsm, "Synology DSM", .serveur),
            ("qnap", .qts, "QNAP QTS", .serveur), ("truenas", .bsd, "TrueNAS", .serveur),
            ("unifi network", .ubiquiti, "Contrôleur UniFi", .serveur), ("unifi os", .ubiquiti, "UniFi OS", .routeur),
            ("edgeos", .ubiquiti, "Ubiquiti EdgeOS", .routeur), ("airos", .ubiquiti, "Ubiquiti airOS", .pointAcces),
            ("pfsense", .bsd, "pfSense", .routeur), ("opnsense", .bsd, "OPNsense", .routeur),
            ("proxmox", .linux, "Proxmox VE", .serveur), ("vmware esxi", .esxi, "VMware ESXi", .serveur),
            ("idrac", .bmc, "Dell iDRAC", .serveur), ("ilo ", .bmc, "HPE iLO", .serveur), ("integrated lights-out", .bmc, "HPE iLO", .serveur),
            ("routeros", .routeros, "MikroTik RouterOS", .routeur), ("mikrotik", .routeros, "MikroTik RouterOS", .routeur),
            ("sophos", .network, "Pare-feu Sophos", .routeur), ("sonicwall", .network, "Pare-feu SonicWall", .routeur),
            ("laserjet", .printer, "Imprimante HP", .imprimante), ("officejet", .printer, "Imprimante HP", .imprimante),
            ("hp color", .printer, "Imprimante HP", .imprimante), ("brother", .printer, "Imprimante Brother", .imprimante),
            ("ricoh", .printer, "Imprimante Ricoh", .imprimante), ("lexmark", .printer, "Imprimante Lexmark", .imprimante),
            ("epson", .printer, "Imprimante Epson", .imprimante), ("xerox", .printer, "Imprimante Xerox", .imprimante),
            ("kyocera", .printer, "Imprimante Kyocera", .imprimante), ("canon ", .printer, "Imprimante Canon", .imprimante),
            ("hikvision", .camera, "Caméra Hikvision", .camera), ("axis", .camera, "Caméra Axis", .camera),
            ("web service", .camera, "Caméra Dahua", .camera), ("dahua", .camera, "Caméra Dahua", .camera),
            ("home assistant", .linux, "Home Assistant", .domotique),
            ("yealink", .embedded, "Téléphone Yealink", .telephoneIP), ("grandstream", .embedded, "Grandstream", .telephoneIP),
        ]
        guard let match = rules.first(where: { lower.contains($0.0) }) else {
            context.add(FPClue(source: source, observed: observed, conclusion: "page web", weight: .faible, port: port))
            return
        }
        // Un titre est moins sûr qu'un en-tête ou un certificat : moyenne, forte pour les marques sans ambiguïté.
        let strong: Set<String> = ["fortigate", "fortiwifi", "fortiap", "fortiswitch", "synology", "diskstation",
                                   "pfsense", "opnsense", "proxmox", "vmware esxi", "idrac", "routeros", "laserjet", "truenas"]
        let weight: FPConfidence = strong.contains(match.0) ? .forte : .moyenne
        context.vote(match.1, name: match.2, type: match.3,
                     clue: FPClue(source: source, observed: observed, conclusion: match.2, weight: weight, port: port))
        if context.result.product == nil { context.result.product = match.2 }
    }

    // MARK: TLS

    /// Sujet et émetteur du certificat : marques des appareils (Fortinet, Synology, HP, Ubiquiti…).
    static func certificate(subject: FPCertName?, issuer: FPCertName?, _ context: inout Context) {
        let port = context.result.port
        let text = [subject?.allText, issuer?.allText].compactMap { $0 }.joined(separator: " ")
        let lower = text.lowercased()
        guard !lower.isEmpty else { return }
        let observed = [subject.map { "sujet " + $0.summary }, issuer.map { "émetteur " + $0.summary }]
            .compactMap { $0 }.filter { !$0.hasSuffix(" ") }.joined(separator: " ; ")
        let clue = { (conclusion: String, weight: FPConfidence) in
            FPClue(source: .tls, observed: observed, conclusion: conclusion, weight: weight, port: port)
        }
        // Fortinet : le nom commun porte le numéro de série (FGT…, FAP…, S1…, FWF…).
        if lower.contains("fortinet") || lower.contains("fortigate") {
            let cn = (subject?.commonName ?? "").uppercased()
            let product: (String, DeviceType)
            if cn.hasPrefix("FAP") { product = ("FortiAP", .pointAcces) }
            else if cn.hasPrefix("FWF") { product = ("FortiWiFi", .routeur) }
            else if cn.hasPrefix("FS") || cn.hasPrefix("S1") || cn.hasPrefix("S2") || cn.hasPrefix("S4") { product = ("FortiSwitch", .switch) }
            else { product = ("FortiGate", .routeur) }
            context.vote(.fortios, name: product.0, type: product.1, clue: clue(product.0, .forte))
            if context.result.product == nil { context.result.product = "Administration " + product.0 }
            return
        }
        let rules: [(String, FPSystemFamily, String, DeviceType?)] = [
            ("synology", .dsm, "Synology DSM", .serveur), ("qnap", .qts, "QNAP QTS", .serveur),
            ("ubiquiti", .ubiquiti, "Ubiquiti UniFi", nil), ("unifi", .ubiquiti, "Ubiquiti UniFi", nil),
            ("remote access group", .bmc, "Dell iDRAC", .serveur), ("idrac", .bmc, "Dell iDRAC", .serveur),
            ("hewlett packard enterprise", .bmc, "HPE iLO", .serveur),
            ("jetdirect", .printer, "Imprimante HP", .imprimante), ("hp inc", .printer, "Imprimante HP", .imprimante),
            ("hewlett-packard", .printer, "Imprimante HP", .imprimante), ("brother", .printer, "Imprimante Brother", .imprimante),
            ("ricoh", .printer, "Imprimante Ricoh", .imprimante), ("lexmark", .printer, "Imprimante Lexmark", .imprimante),
            ("xerox", .printer, "Imprimante Xerox", .imprimante), ("kyocera", .printer, "Imprimante Kyocera", .imprimante),
            ("seiko epson", .printer, "Imprimante Epson", .imprimante), ("canon inc", .printer, "Imprimante Canon", .imprimante),
            ("hikvision", .camera, "Caméra Hikvision", .camera), ("dahua", .camera, "Caméra Dahua", .camera),
            ("axis communications", .camera, "Caméra Axis", .camera),
            ("vmware", .esxi, "VMware ESXi", .serveur), ("pve cluster", .linux, "Proxmox VE", .serveur),
            ("proxmox", .linux, "Proxmox VE", .serveur),
            ("pfsense", .bsd, "pfSense", .routeur), ("opnsense", .bsd, "OPNsense", .routeur), ("ixsystems", .bsd, "TrueNAS", .serveur),
            ("mikrotik", .routeros, "MikroTik RouterOS", .routeur), ("sophos", .network, "Pare-feu Sophos", .routeur),
            ("sonicwall", .network, "Pare-feu SonicWall", .routeur), ("aruba", .arubaOS, "HPE Aruba", nil),
            ("cisco", .ciscoIOS, "Cisco", nil), ("yealink", .embedded, "Téléphone Yealink", .telephoneIP),
            ("grandstream", .embedded, "Grandstream", .telephoneIP),
        ]
        if let match = rules.first(where: { lower.contains($0.0) }) {
            // « HP » seul dans le nom commun (imprimantes : « HP LaserJet M404 », « HPXXXXXX »).
            context.vote(match.1, name: match.2, type: match.3, clue: clue(match.2, .forte))
            if context.result.product == nil { context.result.product = match.2 }
        } else if let cn = subject?.commonName, cn.uppercased().hasPrefix("HP") && cn.count <= 20 && issuer?.organization == nil {
            context.vote(.printer, name: "Imprimante HP", type: .imprimante, clue: clue("Imprimante HP (nom du certificat)", .moyenne))
        } else {
            context.add(clue("certificat sans marque connue", .faible))
        }
    }

    // MARK: Outils

    /// « Apache/2.4.41 » → (Apache, 2.4.41) ; « OpenSSH_8.9p1 » → (OpenSSH, 8.9p1).
    static func productVersion(_ token: String, separators: [Character]) -> (name: String, version: String?) {
        for separator in separators {
            if let index = token.firstIndex(of: separator) {
                let name = String(token[..<index])
                let version = String(token[token.index(after: index)...])
                if !name.isEmpty, version.first?.isNumber == true { return (name, version) }
            }
        }
        return (token, nil)
    }

    /// Mot qui suit `marker` (« vsFTPd 3.0.3) » → « 3.0.3 »), s'il commence par un chiffre.
    static func word(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker, options: .caseInsensitive) else { return nil }
        let rest = text[range.upperBound...].drop { $0 == " " || $0 == "/" || $0 == "_" }
        let token = rest.prefix { !$0.isWhitespace && $0 != ")" && $0 != "(" && $0 != ";" && $0 != "," }
        guard token.first?.isNumber == true else { return nil }
        return String(token)
    }

    /// « 10.0.17763.1 » → 17763.
    static func windowsBuild(fromVersion version: String) -> Int? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 3 && parts[2] > 1000 ? parts[2] : nil
    }

    /// Version de Windows d'après le numéro de build.
    public static func windowsRelease(build: Int) -> String? {
        switch build {
        case 6001, 6002, 6003: return "Vista / Server 2008"
        case 7600, 7601: return "7 / Server 2008 R2"
        case 9200: return "8 / Server 2012"
        case 9600: return "8.1 / Server 2012 R2"
        case 10240: return "10 (1507)"
        case 14393: return "10 (1607) / Server 2016"
        case 17763: return "10 (1809) / Server 2019"
        case 19041...19045: return "10 (2004 à 22H2)"
        case 20348: return "Server 2022"
        case 22000: return "11 (21H2)"
        case 22621, 22631: return "11 (22H2 ou 23H2)"
        case 26100: return "11 (24H2) / Server 2025"
        default: return nil
        }
    }

    /// Version de Windows d'après celle d'IIS.
    static func iisRelease(_ version: String) -> String? {
        switch version {
        case "10.0": return "10 / Server 2016 ou plus récent"
        case "8.5": return "8.1 / Server 2012 R2"
        case "8.0": return "8 / Server 2012"
        case "7.5": return "7 / Server 2008 R2"
        case "7.0": return "Vista / Server 2008"
        case "6.0": return "Server 2003"
        default: return nil
        }
    }
}
