import Foundation
import NetScopeCore

/// Note 72 : partages SMB de démonstration, sans jamais lancer smbutil (aucun trafic).
///
/// - NAS Synology « NAS salle B01 » (10.182.122.154) : déjà lu en invité, huit partages dont IPC$ ;
/// - poste Windows « Poste comptabilité » (10.182.122.117) : déjà lu avec BUREAU\marc, partages
///   administratifs C$, ADMIN$, IPC$, print$ cachés, « Scans » et l'imprimante partagée ;
/// - contrôleur de domaine (10.10.0.10) : NETLOGON et SYSVOL au clic ;
/// - « Lister » sur les autres postes Windows : accès invité refusé (saisir un utilisateur) ;
///   imprimante HP (10.182.122.140) : SMB1 seulement ; tout autre hôte : port 445 fermé.
///
/// Captures : NETSCOPE_DEVICE=10.182.122.154 NETSCOPE_DEVICE_TAB=ports montre la section de la fiche ;
/// NETSCOPE_SMB_FEUILLE=1 dessine la feuille du Scanner par-dessus la fiche Appareil ;
/// NETSCOPE_SMB_CACHES=1 affiche les partages cachés ($).
enum SMBSharesDemo {
    static let nas = "10.182.122.154"
    static let windows = "10.182.122.117"
    static let domainController = "10.10.0.10"

    static var showHidden: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_SMB_CACHES"] != nil
    }

    /// Feuille dessinée dans la page pendant les captures.
    static var showsSheet: Bool {
        RegEnvironment.isSnapshot && ProcessInfo.processInfo.environment["NETSCOPE_SMB_FEUILLE"] != nil
    }

    static let nasShares: [SMBShare] = [
        SMBShare(name: "IPC$", kind: .ipc, comment: "IPC Service (DS920-B01)"),
        SMBShare(name: "Commun", kind: .disk, comment: "Dossiers partagés de toute l’équipe"),
        SMBShare(name: "Comptabilité", kind: .disk, comment: "Pièces comptables et paie"),
        SMBShare(name: "homes", kind: .disk, comment: "Dossiers personnels"),
        SMBShare(name: "photo", kind: .disk, comment: "System default shared folder"),
        SMBShare(name: "Time Machine", kind: .disk, comment: "Sauvegardes des Mac"),
        SMBShare(name: "usbshare1", kind: .disk, comment: "Disque USB (arrière)"),
        SMBShare(name: "HP_LaserJet_M404", kind: .printer, comment: "HP LaserJet Pro M404dn"),
    ]

    static let windowsShares: [SMBShare] = [
        SMBShare(name: "ADMIN$", kind: .disk, comment: "Remote Admin"),
        SMBShare(name: "C$", kind: .disk, comment: "Default share"),
        SMBShare(name: "IPC$", kind: .ipc, comment: "Remote IPC"),
        SMBShare(name: "print$", kind: .disk, comment: "Printer Drivers"),
        SMBShare(name: "Scans", kind: .disk, comment: "Numérisations du copieur"),
        SMBShare(name: "Brother DCP-L2640DW", kind: .printer, comment: "Imprimante de l’accueil"),
    ]

    static let controllerShares: [SMBShare] = [
        SMBShare(name: "ADMIN$", kind: .disk, comment: "Remote Admin"),
        SMBShare(name: "C$", kind: .disk, comment: "Default share"),
        SMBShare(name: "IPC$", kind: .ipc, comment: "Remote IPC"),
        SMBShare(name: "NETLOGON", kind: .disk, comment: "Logon server share"),
        SMBShare(name: "Redirections", kind: .disk, comment: "Bureaux et documents redirigés"),
        SMBShare(name: "SYSVOL", kind: .disk, comment: "Logon server share"),
    ]

    static let backupShares: [SMBShare] = [
        SMBShare(name: "ADMIN$", kind: .disk, comment: "Remote Admin"),
        SMBShare(name: "C$", kind: .disk, comment: "Default share"),
        SMBShare(name: "IPC$", kind: .ipc, comment: "Remote IPC"),
        SMBShare(name: "Sauvegardes", kind: .disk, comment: "Dépôt Veeam"),
    ]

    static let memo: [String: SMBRememberedLogin] = [
        windows: SMBRememberedLogin(user: "BUREAU\\marc", passwordSaved: true),
    ]

    /// Lectures « faites plus tôt » (la fiche du NAS montre déjà son tableau).
    static func initialStates(now: Date = Date()) -> [String: SMBHostState] {
        [
            nas: SMBHostState(listing: SMBShareListing(host: nas, shares: nasShares, reportedCount: nasShares.count,
                                                       access: .guest, date: now.addingTimeInterval(-4 * 60))),
            windows: SMBHostState(listing: SMBShareListing(host: windows, shares: windowsShares, reportedCount: windowsShares.count,
                                                           access: .user("BUREAU\\marc"), date: now.addingTimeInterval(-26 * 60)),
                                  user: "BUREAU\\marc"),
            // Portable Windows : invité et anonyme refusés, les champs de l'utilisateur sont ouverts.
            "10.182.122.113": SMBHostState(error: .accessDenied(guest: true)),
        ]
    }

    /// Réponse fictive à « Lister les partages ».
    static func result(host: String, login: SMBLogin?, now: Date = Date()) -> Result<SMBShareListing, SMBShareError> {
        let access: SMBAccess = login.map { .user($0.display) } ?? .guest
        switch host {
        case nas:
            return .success(SMBShareListing(host: host, shares: nasShares, reportedCount: nasShares.count, access: access, date: now))
        case windows:
            return .success(SMBShareListing(host: host, shares: windowsShares, reportedCount: windowsShares.count,
                                            access: login.map { .user($0.display) } ?? .anonymous, date: now))
        case domainController:
            guard login != nil else { return .failure(.accessDenied(guest: true)) }
            return .success(SMBShareListing(host: host, shares: controllerShares, reportedCount: controllerShares.count,
                                            access: access, date: now))
        case "10.182.122.113", "10.182.122.126":
            return login == nil ? .failure(.accessDenied(guest: true))
                : .success(SMBShareListing(host: host, shares: Array(windowsShares.prefix(4)), access: access, date: now))
        case "10.10.0.31":
            return login == nil ? .failure(.accessDenied(guest: true))
                : .success(SMBShareListing(host: host, shares: backupShares, reportedCount: backupShares.count, access: access, date: now))
        case "10.182.122.140":
            return .failure(.smb1Only)
        default:
            return .failure(.refused)
        }
    }
}
