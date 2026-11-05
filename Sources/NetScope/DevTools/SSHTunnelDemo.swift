import Foundation
import NetScopeCore

// Note 66 et note 78 (Accès distant) : démonstration des tunnels SSH et de l'import de
// ~/.ssh/config (--demo et captures). Rien n'est lancé : les sessions de tunnel de la
// démonstration sont « ouvertes » d'office, avec un journal fictif ; le fichier ~/.ssh/config est
// un texte fixe (le vrai fichier du Mac n'est jamais lu en démonstration).
//
// Captures (NETSCOPE_REMOTE_VIEW) : « tunnel » (onglet du tunnel RDP par le bastion de Laval),
// « tunnel-socks » (proxy SOCKS de la FortiGate), « tunnels » (détails du bastion et de ses
// tunnels), « tunnel-nouveau » (formulaire), « import-ssh » (import de ~/.ssh/config).

enum SSHTunnelDemo {
    /// ~/.ssh/config fictif du technicien.
    static let configText = """
    # ~/.ssh/config — Dany
    Include config.d/*

    Host bastion-laval
        HostName 203.0.113.10
        User ops
        Port 2222
        IdentityFile ~/.ssh/id_bastion

    Host sw-laval-01
        HostName 10.20.0.3
        User admin
        ProxyJump bastion-laval

    Host sw-core
        HostName 10.182.122.2
        User netadmin
        IdentityFile ~/.ssh/id_netscope

    Host nas-syno
        HostName 10.10.0.20
        User admin-nas
        Port 22

    Host fgt-laval
        HostName 10.20.0.1
        User admin
        ProxyJump bastion-laval

    Host srv-linux-01 srv-linux-01.corp.local
        HostName 10.10.0.31
        User dany
        IdentityFile ~/.ssh/id_ed25519

    Host labo-*
        User root
        StrictHostKeyChecking accept-new

    Match host *.lab exec "test -f ~/.ssh/lab"
        User labo

    Host *
        ServerAliveInterval 30
        AddKeysToAgent yes
    """

    static let configFiles: [String: String] = [
        "/Users/dany/.ssh/config.d/clients": """
        Host srv-client-ab
            HostName 198.51.100.24
            User technicien
            ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
        """,
    ]

    static var config: SSHConfigFile {
        let files = configFiles
        let loader = SSHConfigLoader(sshDirectory: "/Users/dany/.ssh", home: "/Users/dany",
                                     read: { files[$0] },
                                     glob: { pattern in files.keys.filter { SSHConfigPattern.glob($0, pattern) }.sorted() })
        return SSHConfigFile.parse(configText, loader: loader)
    }

    /// Connexions du carnet ajoutées par la démonstration : le bastion de Laval et un switch joint
    /// par lui (ProxyJump).
    static func connections(now: Date) -> [RemoteConnection] {
        [
            RemoteConnection(name: "Bastion-Laval", proto: .ssh, host: "203.0.113.10", port: 2222, username: "ops",
                             folder: "Laval › Réseau", isFavorite: false, note: "Debian 12 · bastion du site de Laval",
                             lastConnected: now.addingTimeInterval(-17 * 60), identityFile: "~/.ssh/id_bastion",
                             tunnels: [
                                SSHTunnelSpec(kind: .local, remoteHost: "10.20.0.15", remotePort: 3389, use: .rdp, label: "SRV-LAVAL (RDP)"),
                                SSHTunnelSpec(kind: .local, localPort: 10_443, remoteHost: "10.20.0.1", remotePort: 443, use: .https,
                                              label: "FortiGate-Laval (web)"),
                             ]),
            RemoteConnection(name: "SW-LAVAL-01", proto: .ssh, host: "10.20.0.3", username: "admin",
                             folder: "Laval › Réseau", note: "FortiSwitch 124F · par le bastion de Laval",
                             lastConnected: now.addingTimeInterval(-3 * 3_600), proxyJump: "ops@203.0.113.10:2222"),
        ]
    }

    /// Tunnels ajoutés aux connexions existantes de la démonstration (croquis : SW-CORE-01 et NAS-SYNO).
    static func tunnels(for name: String) -> [SSHTunnelSpec] {
        switch name {
        case "SW-CORE-01":
            return [SSHTunnelSpec(kind: .local, localPort: 8443, remoteHost: "10.182.122.111", remotePort: 443, use: .https,
                                  label: "FortiAP-231F (interface web)")]
        case "NAS-SYNO":
            return [SSHTunnelSpec(kind: .local, localPort: 5001, remoteHost: "127.0.0.1", remotePort: 5001, use: .https, label: "DSM")]
        case "FortiGate-60F":
            return [SSHTunnelSpec(kind: .dynamic, label: "Proxy SOCKS du siège")]
        default:
            return []
        }
    }

    /// Port local de la démonstration (le port voulu, ou celui qu'un choix automatique donnerait).
    static func port(for tunnel: SSHTunnelSpec) -> Int {
        tunnel.preferredLocalPort
    }

    static func openedAt(for tunnel: SSHTunnelSpec) -> Date {
        Date().addingTimeInterval(tunnel.kind == .dynamic ? -42 * 60 : -17 * 60)
    }

    /// Journal fictif d'un tunnel ouvert.
    static func log(for tunnel: SSHTunnelSpec, connection: RemoteConnection, port: Int, command: String,
                    openedAt: Date) -> [SSHTunnelSession.LogLine] {
        func line(_ seconds: Double, _ text: String, _ tone: Tone = .neutral) -> SSHTunnelSession.LogLine {
            SSHTunnelSession.LogLine(date: openedAt.addingTimeInterval(seconds), text: text, tone: tone)
        }
        let key = connection.identityFile.isEmpty ? "agent SSH (id_ed25519)" : "clé \(connection.identityFile)"
        var lines = [
            line(-1.4, "NetScope › " + command),
            line(-1.4, tunnel.localPort == 0 ? "Port local \(port) libre, choisi automatiquement." : "Port local \(port) libre."),
            line(-0.9, "Clé hôte ED25519 de \(connection.host) vérifiée (~/.ssh/known_hosts)."),
            line(-0.4, "Authentifié par la \(key)."),
        ]
        switch tunnel.kind {
        case .local:
            lines.append(line(0, "Tunnel ouvert\u{00A0}: 127.0.0.1:\(port) → \(tunnel.remoteHost):\(tunnel.remotePort).", .success))
            if tunnel.use == .rdp {
                lines.append(line(64, "Connexion de Windows App acceptée (canal 2)."))
            }
        case .dynamic:
            lines.append(line(0, "Proxy SOCKS5 ouvert sur 127.0.0.1:\(port).", .success))
            lines.append(line(310, "channel 4: open failed: connect failed: Connection timed out (10.182.122.250:80)", .warning))
        }
        return lines
    }

    /// Formulaire de la capture « tunnel-nouveau » : VNC d'un poste de Laval par le bastion.
    static func draft(connectionID: UUID) -> SSHTunnelDraft {
        var draft = SSHTunnelDraft(connectionID: connectionID)
        draft.label = "WKS-LAVAL-07 (VNC)"
        draft.remoteHost = "10.20.0.57"
        draft.remotePort = "5900"
        draft.use = .vnc
        return draft
    }

    /// Onglets de tunnel ouverts au lancement de la démonstration.
    @MainActor
    static func openDemoTunnels(in store: RemoteSessionStore) {
        let view = ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"]
        let connections = RemoteDemo.connections
        guard let bastion = connections.first(where: { $0.name == "Bastion-Laval" }), let rdp = bastion.tunnels.first,
              let core = connections.first(where: { $0.name == "SW-CORE-01" }), let web = core.tunnels.first,
              let fortigate = connections.first(where: { $0.name == "FortiGate-60F" }), let socks = fortigate.tunnels.first else { return }
        let rdpSession = SSHTunnelStore.shared.start(rdp, via: bastion)
        store.openTunnel(rdpSession, activate: view == "tunnel")
        let webSession = SSHTunnelStore.shared.start(web, via: core)
        store.openTunnel(webSession, activate: false)
        if view == "tunnel-socks" {
            store.openTunnel(SSHTunnelStore.shared.start(socks, via: fortigate), activate: true)
        }
        if view == "tunnel" || view == "tunnel-socks" {
            RemoteModel.shared.selectedID = (view == "tunnel" ? bastion : fortigate).id
            RemoteModel.shared.showDetails = false
        }
    }
}
