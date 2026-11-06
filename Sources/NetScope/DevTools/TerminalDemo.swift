import Foundation
import NetScopeCore

// Note 57 : démonstration du terminal intégré (--demo) et captures (NETSCOPE_REMOTE_VIEW=terminal
// terminal-serie ou terminal-telnet). Sorties fictives reprises du croquis Remote.dc.html : SW-CORE-01 (Cisco
// IOS XE, « show interfaces status » en couleurs) et la console série d'un switch neuf en
// démarrage. La liaison simulée répond à quelques commandes ; rien ne part sur le réseau ni sur
// un port série.

/// Liaison simulée : texte d'accueil émis dès que la vue connaît sa taille, puis réponses fixes.
final class TerminalDemoTransport: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (TerminalTransportEvent) -> Void)?
    private let lines: [String]
    private let prompt: String
    private let responses: [String: String]
    private let echo: Bool
    private var banner = false
    private var typed: [UInt8] = []
    private var currentPrompt: String

    init(lines: [String], prompt: String = "", responses: [String: String] = [:], echo: Bool = true) {
        self.lines = lines
        self.prompt = prompt
        self.responses = responses
        self.echo = echo
        currentPrompt = prompt
    }

    func start(_ handler: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        self.handler = handler
        handler(.connected)
        // Sans vue (aucun redimensionnement), le texte d'accueil arrive quand même.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.emitBanner() }
    }

    private func emitBanner() {
        lock.lock()
        let first = !banner
        banner = true
        lock.unlock()
        guard first else { return }
        handler?(.data(Array((lines.joined(separator: "\r\n") + currentPrompt).utf8)))
    }

    func resize(columns: Int, rows: Int) {
        emitBanner()
    }

    func send(_ bytes: [UInt8]) {
        var output: [UInt8] = []
        for byte in bytes {
            switch byte {
            case 0x0D:
                let command = String(decoding: typed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                typed.removeAll()
                output += Array("\r\n".utf8)
                if command == "enable" || command == "en" {
                    currentPrompt = currentPrompt.replacingOccurrences(of: ">", with: "#")
                } else if !command.isEmpty {
                    let reply = responses[command] ?? TerminalDemo.invalid(command, prompt: currentPrompt)
                    output += Array(reply.replacingOccurrences(of: "\n", with: "\r\n").utf8)
                    if !reply.hasSuffix("\n") { output += Array("\r\n".utf8) }
                }
                output += Array(currentPrompt.utf8)
            case 0x7F, 0x08:
                if !typed.isEmpty {
                    typed.removeLast()
                    output += [0x08, 0x20, 0x08]
                }
            case 0x03:
                typed.removeAll()
                output += Array("^C\r\n\(currentPrompt)".utf8)
            case 0x20...0x7E:
                typed.append(byte)
                if echo { output.append(byte) }
            default:
                break
            }
        }
        if !output.isEmpty { handler?(.data(output)) }
    }

    func close() {
        handler?(.closed(nil))
    }

    func sendBreak() {}
}

@MainActor
enum TerminalDemo {
    private static let esc = "\u{1B}"
    private static var green: String { esc + "[32m" }
    private static var red: String { esc + "[31m" }
    private static var cyan: String { esc + "[36m" }
    private static var yellow: String { esc + "[33m" }
    private static var dim: String { esc + "[2m" }
    private static var bold: String { esc + "[1m" }
    private static var reset: String { esc + "[0m" }

    /// Onglets ouverts au lancement en démonstration : SSH vers SW-CORE-01 et la console série.
    static func openDemoTabs(in store: RemoteSessionStore) {
        let view = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"]
        let connections = RemoteDemo.connections
        guard let core = connections.first(where: { $0.name == "SW-CORE-01" }),
              let usb = connections.first(where: { $0.proto == .serie }) else { return }
        let ssh = TerminalSession(connection: core)
        ssh.demoTransport = transportFactory(for: core)
        ssh.start()
        let serial = TerminalSession(connection: usb)
        serial.demoTransport = transportFactory(for: usb)
        serial.start()
        // Note 78 : « terminal-serie-xmodem » (envoi XMODEM-1K en cours) et « terminal-serie-fichier »
        // (feuille Transfert de fichier) montrent aussi la console série.
        let serialView = view == "terminal-serie" || view == "terminal-serie-xmodem" || view == "terminal-serie-fichier"
        if view == "terminal-serie-xmodem", let firmware = firmwareFiles.first {
            serial.showDemoTransfer(SerialTransferController.snapshot(file: firmware, proto: .xmodem1K, bytes: 812_032,
                                                                      retries: 2, seconds: 875))
            // 875 s : le débit d'un port à 9600 bauds (≈ 0,93 ko/s en XMODEM-1K), comme la console.
        }
        store.add(ssh, activate: view == "terminal")
        store.add(serial, activate: serialView)
        // Capture « terminal-telnet » : onglet Telnet de SW-ETG2-01 (Aruba, bandeau non chiffré).
        var telnetTarget: RemoteConnection?
        if view == "terminal-telnet", let etg = connections.first(where: { $0.proto == .telnet }) {
            let telnet = TerminalSession(connection: etg)
            telnet.demoTransport = transportFactory(for: etg)
            telnet.start()
            store.add(telnet, activate: true)
            telnetTarget = etg
        }
        // Note 67 : « terminal-plusieurs » : SW-CORE-01, SW-ETG2-01 (Telnet) et le FortiGate ouverts,
        // feuille « Envoyer à plusieurs sessions » avec les deux switchs cochés (rien n'est envoyé).
        if view == "terminal-plusieurs" {
            var opened = [ssh]
            for name in ["SW-ETG2-01", "FortiGate-60F"] {
                guard let connection = connections.first(where: { $0.name == name }) else { continue }
                let session = TerminalSession(connection: connection)
                session.demoTransport = transportFactory(for: connection)
                session.start()
                store.add(session, activate: false)
                opened.append(session)
            }
            store.activeID = ssh.id
            RemoteModel.shared.selectedID = core.id
            RemoteModel.shared.showDetails = false
            let switches = opened.filter { $0.connection.name.hasPrefix("SW-") }.map(\.id)
            broadcastRequest = TerminalBroadcastRequest(command: "show running-config", sendsReturn: true, selected: Set(switches))
        }
        if view == "terminal" || serialView || telnetTarget != nil {
            // Capture : la connexion de l'onglet choisie, le terminal sur toute la largeur.
            RemoteModel.shared.selectedID = (telnetTarget ?? (view == "terminal" ? core : usb)).id
            RemoteModel.shared.showDetails = false
        }
    }

    /// Liaison simulée d'une connexion du carnet (Cisco, FortiGate, Aruba, Linux ou console série).
    static func transportFactory(for connection: RemoteConnection) -> () -> TerminalTransport {
        let note = connection.note.lowercased()
        if connection.proto == .serie {
            return { TerminalDemoTransport(lines: bootLines, prompt: "Switch>", responses: iosResponses(prompt: "Switch")) }
        }
        if note.contains("cisco") {
            let prompt = connection.name + "#"
            return {
                TerminalDemoTransport(lines: ciscoBanner(connection) + [green + bold + prompt + reset + " show interfaces status"]
                                        + interfaceStatus.components(separatedBy: "\n"),
                                      prompt: green + bold + prompt + reset + " ", responses: iosResponses(prompt: connection.name))
            }
        }
        if note.contains("fortigate") || note.contains("fortios") {
            let prompt = connection.name + " # "
            return {
                TerminalDemoTransport(lines: [dim + "Clé hôte ED25519 vérifiée (~/.ssh/known_hosts)." + reset, ""],
                                      prompt: prompt, responses: ["get system status": fortiStatus])
            }
        }
        if note.contains("aruba") {
            let prompt = connection.name + "# "
            return {
                TerminalDemoTransport(lines: [yellow + "Telnet : connexion à \(connection.host):\(connection.port) établie (non chiffrée)." + reset,
                                              "", "HPE Networking", "", "Press any key to continue", "", "Password: ********", "",
                                              bold + prompt + reset + "show interfaces brief"] + arubaInterfaces.components(separatedBy: "\n"),
                                      prompt: bold + prompt + reset,
                                      responses: ["show interfaces brief": arubaInterfaces, "show vlans": arubaVlans])
            }
        }
        let prompt = "\(connection.username.isEmpty ? "admin" : connection.username)@\(connection.name):~$ "
        return {
            TerminalDemoTransport(lines: ["Linux \(connection.name) 4.4.302+ #72806 SMP x86_64 GNU/Linux", ""],
                                  prompt: green + prompt + reset,
                                  responses: ["uptime": " 10:41:07 up 63 days,  2:18,  1 user,  load average: 0.21, 0.30, 0.27"])
        }
    }

    nonisolated static func invalid(_ command: String, prompt: String) -> String {
        "% Invalid input detected at '^' marker."
    }

    private static func ciscoBanner(_ connection: RemoteConnection) -> [String] {
        [
            dim + "Clé hôte ECDSA de \(connection.host) vérifiée (SHA256:q3Vt…KvB5M) · clé ed25519 « id_netscope »." + reset,
            "",
            yellow + "*** Accès réservé au personnel autorisé — activité journalisée ***" + reset,
            "",
        ]
    }

    /// « show interfaces brief » de SW-ETG2-01 (Aruba 2930F), repris du croquis Remote.dc.html.
    static var arubaInterfaces: String {
        let up: [Int: String] = [3: "1000FDx", 7: "1000FDx", 9: "100FDx", 14: "1000FDx", 18: "100FDx", 24: "1000FDx"]
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
        var lines = ["", " Status and Counters - Port Status", "",
                     "                    | Intrusion                           MDI   Flow  Bcast",
                     "  Port  Type        | Alert     Enabled Status Mode       Mode  Ctrl  Limit",
                     "  ----- ----------- + --------- ------- ------ ---------- ----- ----- ------"]
        for port in 1...28 {
            let mode = up[port]
            let type = port > 24 ? "SFP+SR   " : "100/1000T"
            let status = mode != nil ? green + "Up    " + reset : red + "Down  " + reset
            lines.append("  " + pad(String(port), 5) + " " + type + "   | No        Yes     " + status + " "
                         + pad(mode ?? (port > 24 ? "." : "1000FDx"), 10) + " " + (mode != nil ? "MDIX " : "Auto ") + " off   0")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let arubaVlans = """

         Status and Counters - VLAN Information

          Maximum VLANs to support : 256
          Primary VLAN : DEFAULT_VLAN

          VLAN ID Name                             | Status     Voice Jumbo
          ------- -------------------------------- + ---------- ----- -----
          1       DEFAULT_VLAN                     | Port-based No    No
          20      WIFI                             | Port-based No    No
          30      IMPRESSION                       | Port-based No    No

        """

    /// « show interfaces status » de SW-CORE-01, en couleurs (état et VLAN).
    static var interfaceStatus: String {
        let rows: [(String, String, String, String, String, String)] = [
            ("Gi1/0/1", "FortiGate-60F", "connected", "trunk", "a-full", "a-1000"),
            ("Gi1/0/2", "", "notconnect", "1", "auto", "auto"),
            ("Gi1/0/12", "FortiAP-231F", "connected", "trunk", "a-full", "a-1000"),
            ("Gi1/0/22", "WKS346", "connected", "1", "a-full", "a-1000"),
            ("Gi1/0/23", "WKS341", "notconnect", "1", "auto", "auto"),
            ("Gi1/0/33", "CAM-QUAI", "connected", "40", "a-full", "a-100"),
            ("Gi1/0/34", "CAM-AXIS", "connected", "40", "a-full", "a-100"),
            ("Gi1/0/40", "SRV-AD-01", "connected", "100", "a-full", "a-1000"),
            ("Gi1/0/41", "SRV-FICHIERS", "connected", "100", "a-full", "a-1000"),
            ("Gi1/0/42", "NAS-SYNO", "connected", "100", "a-full", "a-1000"),
            ("Gi1/0/47", "SW-ETG2-01", "connected", "trunk", "a-full", "a-1000"),
        ]
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
        func left(_ text: String, _ width: Int) -> String { String(repeating: " ", count: max(width - text.count, 0)) + text }
        var lines = ["", bold + "Port         Name               Status       Vlan       Duplex  Speed Type" + reset]
        for row in rows {
            let status = row.2 == "connected" ? green + pad(row.2, 13) + reset : red + pad(row.2, 13) + reset
            let vlan = row.3 == "trunk" ? cyan + pad(row.3, 11) + reset : pad(row.3, 11)
            lines.append(pad(row.0, 13) + pad(row.1, 19) + status + vlan + left(row.4, 6) + " " + left(row.5, 6) + " 10/100/1000BaseTX")
        }
        lines.append("Te1/1/1                         " + red + "notconnect   " + reset + "1            full    10G SFP-10GBase-SR")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func iosResponses(prompt: String) -> [String: String] {
        [
            "show interfaces status": interfaceStatus,
            "sh int status": interfaceStatus,
            "show version": """
            Cisco IOS XE Software, Version 17.09.04a
            Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)

            \(prompt) uptime is 41 weeks, 3 days, 7 hours, 12 minutes
            System image file is "flash:packages.conf"
            cisco C9300-48P (X86) processor with 1331521K/6147K bytes of memory.
            Processor board ID FOC2418L0QX
            """,
            "show vlan brief": """

            VLAN Name                             Status    Ports
            ---- -------------------------------- --------- -------------------------------
            1    default                          active    Gi1/0/2, Gi1/0/3, Gi1/0/22, Gi1/0/23
            40   CAMERAS                          active    Gi1/0/33, Gi1/0/34
            100  SERVEURS                         active    Gi1/0/40, Gi1/0/41, Gi1/0/42
            """,
            "show mac address-table | include 94dd": "  30    94dd.f818.157d    DYNAMIC     Gi1/0/47",
            "show lldp neighbors": """
            Device ID           Local Intf     Hold-time  Capability      Port ID
            FortiGate-60F       Gi1/0/1        120        B,R             port1
            FortiAP-231F        Gi1/0/12       120        W               lan1
            SW-ETG2-01          Gi1/0/47       120        B               24

            Total entries displayed: 3
            """,
        ]
    }

    private static let fortiStatus = """
    Version: FortiGate-60F v7.4.4,build2662,240514 (GA.F)
    Serial-Number: FGT60FTK2209XXXX
    Hostname: FortiGate-60F
    Operation Mode: NAT
    """

    /// Démarrage d'un Catalyst 9200L neuf sur la console (croquis).
    static let bootLines: [String] = [
        "Initializing Hardware ...",
        "",
        "System Bootstrap, Version 17.6.1r[FC2], RELEASE SOFTWARE (P)",
        "Copyright (c) 1994-2021 by cisco Systems, Inc.",
        "",
        "Current image running: Boot ROM0",
        "Last reset cause: PowerOn",
        "C9200L-24P-4G platform with 2097152 Kbytes of main memory",
        "",
        "boot: attempting to boot from [flash:packages.conf]",
        "boot: reading file packages.conf",
        "##############################################################################",
        "",
        "Waiting for 120 seconds for other switches to boot",
        "Switch number is 1",
        "All switches in the stack have been discovered. Accelerating discovery",
        "",
        "cisco C9200L-24P-4G (ARM64) processor with 1295437K/3071K bytes of memory.",
        "Processor board ID JAE25110XYZ",
        "24 Gigabit Ethernet interfaces",
        "4 Gigabit Ethernet interfaces (SFP)",
        "",
        "         --- System Configuration Dialog ---",
        "",
        "Would you like to enter the initial configuration dialog? [yes/no]: no",
        "",
        "Press RETURN to get started!",
        "",
        "\u{1B}[33m*Nov  3 10:29:47.112: %SYS-5-RESTART: System restarted --\u{1B}[0m",
        "\u{1B}[32m*Nov  3 10:29:48.903: %LINK-3-UPDOWN: Interface GigabitEthernet1/0/24, changed state to up\u{1B}[0m",
        "\u{1B}[32m*Nov  3 10:29:49.904: %LINEPROTO-5-UPDOWN: Line protocol on Interface GigabitEthernet1/0/24, changed state to up\u{1B}[0m",
        "",
        "",
    ]

    /// Captures (note 67) : feuille « Envoyer à plusieurs sessions » dessinée dans la page.
    static var broadcastRequest: TerminalBroadcastRequest?

    /// Captures : feuille « Transfert de fichier » dessinée dans la page.
    static var showsTransferSheet: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] == "terminal-serie-fichier"
    }

    /// Firmware fictif de la démonstration (contenu sans valeur, taille réaliste).
    static var firmwareFiles: [SerialFile] {
        [SerialFile(name: "c2960x-universalk9-mz.152-7.E9.bin", data: [UInt8](repeating: 0x5A, count: 1_312_444),
                    modified: Date(timeIntervalSince1970: 1_790_000_000))]
    }

    /// Configuration envoyée par le switch simulé (réception XMODEM en démonstration).
    nonisolated static let sampleConfig = (["!", "version 17.6", "hostname Switch", "!"]
        + (1...24).map { "interface GigabitEthernet1/0/\($0)\n switchport access vlan 1\n spanning-tree portfast\n!" }
        + ["line con 0", " exec-timeout 0 0", "end", ""]).joined(separator: "\n")

    /// Ports série de la démonstration (croquis).
    static let serialPorts: [SerialPortInfo] = [
        "/dev/cu.usbserial-A10K", "/dev/cu.usbmodem14201", "/dev/cu.Bluetooth-Incoming-Port",
    ].map(SerialPortInfo.init(path:))
}
