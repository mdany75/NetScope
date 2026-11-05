import Foundation
import NetScopeCore

/// Connexions de démonstration, reprises du croquis (docs/croquis/Remote.dc.html).
enum RemoteDemo {
    static let connections: [RemoteConnection] = {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        return [
            RemoteConnection(name: "SW-CORE-01", proto: .ssh, host: "10.182.122.2", username: "netadmin",
                             folder: "Siège › Réseau", isFavorite: true, note: "Cisco Catalyst 9300-48P · IOS XE 17.9.4a", lastConnected: ago(0.2)),
            RemoteConnection(name: "SW-ETG2-01", proto: .telnet, host: "10.182.122.3", username: "manager",
                             folder: "Siège › Réseau", note: "Aruba 2930F-24G · WC.16.11", lastConnected: ago(0.1)),
            RemoteConnection(name: "FortiGate-60F", proto: .ssh, host: "10.182.122.1", username: "admin",
                             folder: "Siège › Réseau", isFavorite: true, note: "Fortinet FortiGate-60F · FortiOS 7.4", lastConnected: ago(20)),
            RemoteConnection(name: "SRV-FICHIERS", proto: .rdp, host: "10.10.0.12", username: "CORP\\dmenard",
                             folder: "Siège › Serveurs", note: "Windows Server 2022 Standard", lastConnected: ago(96),
                             display: RemoteDisplaySettings(mode: .window, windowSize: .r1440x900)),
            RemoteConnection(name: "NAS-SYNO", proto: .ssh, host: "10.10.0.20", username: "admin-nas",
                             folder: "Siège › Serveurs", note: "Synology · DSM 7.2", lastConnected: ago(150)),
            RemoteConnection(name: "WKS346", proto: .rdp, host: "10.182.122.117", username: "CORP\\dmenard",
                             folder: "Siège › Postes", isFavorite: true, note: "Dell · Windows 11 Pro 23H2", lastConnected: ago(0.3),
                             display: RemoteDisplaySettings(mode: .window, windowSize: .fit)),
            RemoteConnection(name: "WKS341", proto: .rdp, host: "10.182.122.146", username: "CORP\\dmenard",
                             folder: "Siège › Postes", note: "Dell · Windows 11 Pro", lastConnected: ago(170)),
            // Note 57 : poste Windows joint en VNC (session intégrée, DevTools/VNCDemo.swift).
            RemoteConnection(name: "WKS352", proto: .vnc, host: "10.182.122.152",
                             folder: "Siège › Postes", note: "Dell OptiPlex · Windows 11 Pro · UltraVNC", lastConnected: ago(0.05),
                             display: RemoteDisplaySettings(mode: .window, vncScale: .fit)),
            RemoteConnection(name: "Macmini-de-Dany", proto: .vnc, host: "10.182.122.135", username: "dany",
                             folder: "Siège › Postes", note: "Apple Mac mini · ce Mac", lastConnected: ago(0.25),
                             display: RemoteDisplaySettings(mode: .window, vncScale: .fit)),
            RemoteConnection(name: "USB-série", proto: .serie, host: "/dev/cu.usbserial-A10K", port: 9600,
                             folder: "Console", note: "Adaptateur FTDI FT232R → câble console RJ45", lastConnected: ago(0.3)),
            // Note 50 : transferts de fichiers (navigateur intégré, DevTools/FileTransferDemo.swift).
            RemoteConnection(name: "NAS-SYNO · sauvegardes", proto: .sftp, host: "10.10.0.20", username: "admin-nas",
                             folder: "Siège › Serveurs", isFavorite: true, note: "Synology DS920+ · sauvegardes et firmwares",
                             lastConnected: ago(0.15),
                             transfer: FileTransferSettings(sftpAuth: .password, remoteDirectory: "/volume1/sauvegardes")),
            RemoteConnection(name: "SW-ETG2-01 · FTP", proto: .ftp, host: "10.182.122.3", username: "manager",
                             folder: "Siège › Réseau", note: "Aruba 2930F · images et configuration", lastConnected: ago(30),
                             transfer: FileTransferSettings(dataMode: .passive)),
        ]
        // Note 66 : tunnels du croquis (SW-CORE-01, NAS-SYNO), proxy SOCKS de la FortiGate, bastion
        // de Laval et switch joint par lui (DevTools/SSHTunnelDemo.swift).
        .map { connection -> RemoteConnection in
            var copy = connection
            copy.tunnels = SSHTunnelDemo.tunnels(for: connection.name)
            return copy
        } + SSHTunnelDemo.connections(now: now)
        // Note 6 : postes RustDesk (DevTools/RustDeskDemo.swift).
        + RustDeskDemo.connections(now: now)
    }()

    static func reachability(for connections: [RemoteConnection]) -> [UUID: RemoteReachability] {
        var result: [UUID: RemoteReachability] = [:]
        for connection in connections {
            // Note 6 : un poste RustDesk désigné par son ID n'est pas sondé (serveur d'ID).
            if connection.proto == .rustdesk, connection.rustDeskTarget?.isDirect != true { continue }
            result[connection.id] = connection.name == "WKS341" ? .unreachable : .reachable
        }
        return result
    }
}
