import Foundation
import NetScopeCore
import SwiftUI

// Note 50 : « Transférer des fichiers › Ouvrir en FTP, FTPS ou SFTP » depuis un appareil (fiche
// Appareil, Scanner, Inventaire). Un choix n'est actif que si son port était ouvert au dernier scan
// (21, 990 et 22, ou le port réglé dans la connexion du carnet) ; sinon il est grisé, et
// « Vérifier les ports » les teste tout de suite (note 34), à la demande seulement.

/// Une entrée du menu.
struct FileTransferOpenOption: Identifiable {
    var proto: RemoteProtocol
    var port: Int
    var isOpen: Bool
    var id: String { proto.rawValue }

    var title: String {
        isOpen ? "Ouvrir en \(proto.label) (port \(port))" : "Ouvrir en \(proto.label) — port \(port) non ouvert"
    }

    /// Choix proposés pour un hôte : port de la connexion du carnet s'il y en a une, sinon le port usuel.
    @MainActor
    static func options(host: String, openPorts: [UInt16]) -> [FileTransferOpenOption] {
        RemoteProtocol.transferProtocols.map { proto in
            let saved = RemoteModel.shared.connections.first { $0.host == host && $0.proto == proto }
            let port = saved?.port ?? proto.defaultPort
            return FileTransferOpenOption(proto: proto, port: port, isOpen: openPorts.contains(UInt16(clamping: port)))
        }
    }
}

/// Sous-menu « Transférer des fichiers » des menus contextuels (Scanner, Inventaire).
struct FileTransferOpenMenu: View {
    let host: String
    let name: String
    let openPorts: [UInt16]
    var deviceID: Device.ID?

    var body: some View {
        Menu("Transférer des fichiers") {
            FileTransferOpenMenuItems(host: host, name: name, openPorts: openPorts, deviceID: deviceID)
        }
    }
}

/// Les choix du menu (aussi dans le bouton « Fichiers » de la fiche Appareil).
struct FileTransferOpenMenuItems: View {
    @EnvironmentObject private var state: AppState
    let host: String
    let name: String
    let openPorts: [UInt16]
    /// Appareil du scan à mettre à jour après « Vérifier les ports » (nil : Inventaire d'un autre site).
    var deviceID: Device.ID?

    var body: some View {
        let options = FileTransferOpenOption.options(host: host, openPorts: openPorts)
        Group {
            ForEach(options) { option in
                Button(option.title) {
                    RemoteModel.shared.openFileTransfer(host: host, name: name, proto: option.proto, port: option.port, state: state)
                }
                .disabled(!option.isOpen)
            }
            let closed = options.filter { !$0.isOpen }
            if !closed.isEmpty {
                Divider()
                Button("Vérifier le" + (closed.count > 1 ? "s ports " : " port ") + closed.map { String($0.port) }.joined(separator: ", ")) {
                    FileTransferPortCheck.run(host: host, name: name, ports: options.map(\.port), deviceID: deviceID, state: state)
                }
            }
        }
    }
}

/// Test immédiat des ports de transfert d'un appareil (connexion TCP seulement, aucune identification).
@MainActor
enum FileTransferPortCheck {
    static func run(host: String, name: String, ports: [Int], deviceID: Device.ID?, state: AppState) {
        let list = ports.map { UInt16(clamping: $0) }
        guard !RegEnvironment.isSandboxed else {
            state.navPrompt = NavPrompt(kind: .message, title: "Ports de transfert de \(name)",
                                        message: "Démonstration\u{00A0}: aucun port n’est sondé (\(list.map(String.init).joined(separator: ", "))).")
            return
        }
        guard let ip = IPv4Address(host) else {
            state.navPrompt = NavPrompt(kind: .message, title: "Ports de transfert de \(name)", message: "Adresse IPv4 invalide\u{00A0}: \(host).")
            return
        }
        Task {
            let open = await PortProber().openPorts(ip, ports: list, timeout: .milliseconds(1_500), concurrency: list.count)
            if let deviceID, var device = state.device(withID: deviceID) {
                device.openPorts = ScanController.mergedPorts(open, probed: Set(list), known: device.openPorts)
                device.lastSeen = Date()
                state.merge([device])
            }
            let lines = list.map { port -> String in
                let proto = RemoteProtocol.transferProtocols.first { $0.defaultPort == Int(port) }
                    ?? RemoteModel.shared.connections.first { $0.host == host && $0.port == Int(port) && $0.proto.isFileTransfer }?.proto
                let label = proto.map { " (\($0.label))" } ?? ""
                return "\(port)\(label)\u{00A0}: \(open.contains(port) ? "ouvert" : "fermé ou filtré")"
            }
            let hint = open.isEmpty
                ? "Aucun service de transfert ne répond\u{00A0}: il est peut-être désactivé sur l’appareil, ou filtré par un pare-feu."
                : "Le menu « Transférer des fichiers » est à jour."
            state.navPrompt = NavPrompt(kind: .message, title: "Ports de transfert de \(name)",
                                        message: lines.joined(separator: " · ") + ".\n" + hint)
        }
    }
}
