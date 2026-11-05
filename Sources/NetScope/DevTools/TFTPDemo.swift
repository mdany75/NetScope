import Foundation
import NetScopeCore

/// Démonstration de l'outil « TFTP » (`--demo`, note 51) : serveur actif sur 10.182.122.135:69
/// (dossier « NetScope TFTP », lecture et écriture), mise à jour du switch SW-ETG2-01 en cours,
/// sauvegarde de sa configuration, provisionnement des téléphones Yealink, un refus et un délai
/// dépassé. Rien n'est envoyé sur le réseau ni écrit sur le disque ; le client rejoue un transfert
/// fictif. NETSCOPE_OUTIL_DEMO=tftp ouvre l'outil pour la capture ; NETSCOPE_TFTP_DEMO=client
/// montre le client (dernier transfert réussi), =arrete le serveur arrêté.
@MainActor
enum TFTPDemo {
    static let root = "/Users/technicien/Documents/NetScope TFTP"

    static let ethernet = LocalInterface(name: "en7", address: IPv4Address("192.168.1.50")!, netmask: IPv4Address("255.255.255.0")!,
                                         kind: .ethernet)

    static func apply(to model: TFTPModel) {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let variant = ProcessInfo.processInfo.environment["NETSCOPE_TFTP_DEMO"] ?? ""
        model.rootPath = root
        model.interfaceName = "en0"
        model.portText = "69"
        model.allowWrite = true
        model.allowOverwrite = false
        model.autoStopMinutes = 15
        model.maxBlockSize = TFTPLimits.maxBlockSize
        model.maxWindowSize = 16
        let site = model.siteKey
        let files = [
            TFTPSharedFile(path: "805ec03a6121.cfg", size: 2_304, modified: ago(3 * 86_400)),
            TFTPSharedFile(path: "805ec03a6123.cfg", size: 2_356, modified: ago(3 * 86_400)),
            TFTPSharedFile(path: "firmware/FGT_60F-v7.4.5.F-build2702.out", size: 98_041_856, modified: ago(9 * 86_400)),
            TFTPSharedFile(path: "firmware/T33G-124.86.0.40.rom", size: 33_554_432, modified: ago(9 * 86_400)),
            TFTPSharedFile(path: "firmware/T54W-96.86.0.70.rom", size: 41_943_040, modified: ago(9 * 86_400)),
            TFTPSharedFile(path: "firmware/WC_16_11_0012.swi", size: 31_457_280, modified: ago(2 * 86_400)),
            TFTPSharedFile(path: "SW-ETG2-01.cfg", size: 18_432, modified: ago(7 * 60)),
            TFTPSharedFile(path: "y000000000000.cfg", size: 6_912, modified: ago(3 * 86_400)),
        ]
        let records = [
            TFTPTransferRecord(date: ago(5 * 60), role: .server, flow: .toDevice, peer: "10.182.122.3", peerName: "Switch étage 2",
                               filename: "firmware/WC_16_11_0012.swi", bytes: 19_503_513, total: 31_457_280, seconds: 23, status: .running,
                               detail: "blksize 1468 · tsize 30,0\u{00A0}Mio · octet", site: site, blockSize: 1_468),
            TFTPTransferRecord(date: ago(7 * 60), role: .server, flow: .fromDevice, peer: "10.182.122.3", peerName: "Switch étage 2",
                               filename: "SW-ETG2-01.cfg", bytes: 18_432, total: 18_432, seconds: 0.41, status: .done,
                               detail: "blksize 512 · octet", site: site, blockSize: 512),
            TFTPTransferRecord(date: ago(11 * 60), role: .server, flow: .toDevice, peer: "10.182.122.123", peerName: "Téléphone conférence 2.08",
                               filename: "firmware/T33G-124.86.0.40.rom", bytes: 1_204_224, total: 33_554_432, seconds: 21, status: .failed,
                               detail: "Délai dépassé\u{00A0}: aucune réponse après 5 retransmissions.", site: site, blockSize: 1_468,
                               reason: "Délai dépassé"),
            TFTPTransferRecord(date: ago(12 * 60), role: .server, flow: .toDevice, peer: "10.182.122.122", peerName: "SIP-T46U",
                               filename: "805ec03a6122.cfg", status: .refused,
                               detail: "Fichier introuvable dans le dossier partagé\u{00A0}: «\u{00A0}805ec03a6122.cfg\u{00A0}».", site: site,
                               reason: "Fichier introuvable"),
            TFTPTransferRecord(date: ago(13 * 60), role: .server, flow: .toDevice, peer: "10.182.122.121", peerName: "Téléphone accueil",
                               filename: "firmware/T54W-96.86.0.70.rom", bytes: 41_943_040, total: 41_943_040, seconds: 36.8, status: .done,
                               detail: "blksize 1468 · tsize 40,0\u{00A0}Mio · octet", site: site, blockSize: 1_468),
            TFTPTransferRecord(date: ago(14 * 60), role: .server, flow: .toDevice, peer: "10.182.122.121", peerName: "Téléphone accueil",
                               filename: "805ec03a6121.cfg", bytes: 2_304, total: 2_304, seconds: 0.04, status: .done,
                               detail: "blksize 1468 · octet", site: site, blockSize: 1_468),
            TFTPTransferRecord(date: ago(14 * 60 + 2), role: .server, flow: .toDevice, peer: "10.182.122.121", peerName: "Téléphone accueil",
                               filename: "y000000000000.cfg", bytes: 6_912, total: 6_912, seconds: 0.06, status: .done,
                               detail: "blksize 1468 · octet", site: site, blockSize: 1_468),
            TFTPTransferRecord(date: ago(26 * 3_600), role: .client, flow: .fromDevice, peer: "10.182.122.2", peerName: "Switch cœur",
                               filename: "SW-CORE-01-confg", bytes: 12_288, total: 12_288, seconds: 0.3, status: .done,
                               detail: "blksize 512 · octet · options refusées par l’appareil (RFC 1350)", site: site, blockSize: 512),
        ]
        model.setDemo(records: records, files: files, interfaces: [DemoData.interface, ethernet],
                      firewall: TFTPFirewallStatus(enabled: true, blockAll: false, app: .allowed))
        if variant == "arrete" {
            model.setDemoServer(running: false, port: 69, startedAt: nil, remaining: nil, activeTransfers: 0)
        } else {
            model.setDemoServer(running: true, port: 69, startedAt: ago(14 * 60 + 30), remaining: 15 * 60, activeTransfers: 1)
        }
        // Client : sauvegarde de la configuration du switch cœur (Cisco), vers le dossier partagé.
        model.clientHost = "10.182.122.2"
        model.clientDirection = .get
        model.remoteName = "SW-CORE-01-confg"
        model.localPath = root + "/SW-CORE-01-confg.txt"
        model.clientBlockSize = TFTPLimits.ethernetBlockSize
        if variant == "client" {
            model.mode = .client
            model.setDemoClient(bytes: 12_288, total: 12_288, running: false,
                                result: (.success, "Transfert réussi",
                                         "«\u{00A0}SW-CORE-01-confg\u{00A0}» reçu de Switch cœur · 10.182.122.2\u{00A0}: 12,0\u{00A0}Kio en 300\u{00A0}ms (40,0\u{00A0}Kio/s)."))
        }
    }

    /// Transfert fictif du client (aucun paquet envoyé) : progression puis réussite.
    static func runClient(model: TFTPModel, recordID: UUID) {
        Task { @MainActor in
            let total: Int64 = 12_288
            for step in 1...4 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                model.clientProgress(id: recordID, bytes: total * Int64(step) / 4, total: total)
            }
            model.finishClient(id: recordID, result: TFTPClient.Result(bytes: total, seconds: 0.6,
                                                                       settings: TFTPTransferSettings(blockSize: 512, mode: .octet),
                                                                       withoutOptions: true),
                               failure: nil)
        }
    }
}
