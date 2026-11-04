import Foundation
import NetScopeCore

/// Note 52 : noms d'utilisateur SSH retenus en démonstration (aucun fichier lu ni écrit, aucun
/// secret). Le switch cœur garde « netadmin » avec la clé de l'identifiant « ssh-netadmin » des
/// Réglages, l'imprimante d'accueil « admin » ; le site Siège retient « netadmin ».
///
/// Captures : NETSCOPE_SSH_FEUILLE=1 dessine la feuille de connexion par-dessus la fiche Appareil
/// (NETSCOPE_DEVICE choisit l'appareil, ex. 10.182.122.2 pour le switch cœur).
@MainActor
enum QuickLoginDemo {
    static func memory(credentials: [RemoteCredential], now: Date = Date()) -> QuickLoginMemory {
        let siege = SitesDemo.siegeID
        let netadmin = credentials.first { $0.name == "ssh-netadmin" }
        var memory = QuickLoginMemory()
        memory.entries = [
            QuickLoginEntry(proto: .ssh, mac: "70:0F:6A:91:4C:02", host: "10.182.122.2", siteID: siege, user: "netadmin",
                            auth: .key, keyPath: "~/.ssh/id_ed25519", credentialID: netadmin?.id,
                            lastUsed: now.addingTimeInterval(-26 * 60)),
            QuickLoginEntry(proto: .ssh, mac: "94:DD:F8:18:15:7D", host: "10.182.122.111", siteID: siege, user: "admin",
                            lastUsed: now.addingTimeInterval(-3 * 3600)),
            QuickLoginEntry(proto: .ssh, host: "10.182.122.40", siteID: siege, user: "admin", port: 2222, auth: .password,
                            skipPrompt: true, lastUsed: now.addingTimeInterval(-2 * 86_400)),
        ]
        memory.recentUsers = ["netadmin", "admin", "manager", "root"]
        return memory
    }

    /// Feuille dessinée dans la page pendant les captures.
    static var showsSheet: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_SSH_FEUILLE"] != nil
    }
}
