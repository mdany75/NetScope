import Darwin
import Foundation

// Erreurs de montage (NetFS) et d'écriture d'un partage, expliquées en clair (note 55) : mauvais
// mot de passe, partage introuvable, SMB1 refusé, droits d'écriture… Les codes viennent de
// NetFSMountURLSync (errno ou codes ENETFS* de <NetFS/NetFS.h>) et des appels d'écriture.

public enum DiskShareProblem: Equatable, Sendable {
    case wrongPassword
    case passwordExpired
    case accountRestricted
    case shareNotFound
    case noShares
    case protocolVersion
    case authMethod
    case unreachable
    case timeout
    case refused
    case accessDenied
    case cancelled
    case readOnly
    case writeDenied
    case diskFull
    case other(Int32)

    // Codes propres à NetFS (<NetFS/NetFS.h>).
    public static let netfsPasswordNeedsChange: Int32 = -5045
    public static let netfsPasswordPolicy: Int32 = -5046
    public static let netfsAccountRestricted: Int32 = -5999
    public static let netfsNoSharesAvailable: Int32 = -5998
    public static let netfsNoAuthMechanism: Int32 = -5997
    public static let netfsNoProtocolVersion: Int32 = -5996
    /// userCanceledErr de Carbon (fenêtre d'identification fermée).
    public static let userCanceled: Int32 = -128

    /// Problème d'un code renvoyé par NetFSMountURLSync ; nil pour 0 (réussi) et EEXIST (déjà
    /// monté : ce n'est pas une erreur, le partage est simplement réutilisé).
    public static func mount(code: Int32) -> DiskShareProblem? {
        switch code {
        case 0, EEXIST: return nil
        case EAUTH: return .wrongPassword
        case netfsPasswordNeedsChange, netfsPasswordPolicy: return .passwordExpired
        case netfsAccountRestricted: return .accountRestricted
        case ENOENT, ENOTDIR: return .shareNotFound
        case netfsNoSharesAvailable: return .noShares
        case netfsNoProtocolVersion, EPROTONOSUPPORT, ENOTSUP, EPROGMISMATCH, EPROGUNAVAIL, ERPCMISMATCH: return .protocolVersion
        case netfsNoAuthMechanism, ENEEDAUTH: return .authMethod
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL: return .unreachable
        case ETIMEDOUT: return .timeout
        case ECONNREFUSED, ECONNRESET: return .refused
        case EACCES, EPERM: return .accessDenied
        case ECANCELED, userCanceled: return .cancelled
        default: return .other(code)
        }
    }

    /// Problème d'une écriture refusée dans le partage monté (errno).
    public static func write(errno code: Int32) -> DiskShareProblem {
        switch code {
        case EROFS: return .readOnly
        case EACCES, EPERM: return .writeDenied
        case ENOSPC, EDQUOT: return .diskFull
        case ENOENT, ENOTDIR: return .shareNotFound
        case ETIMEDOUT: return .timeout
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return .unreachable
        default: return .other(code)
        }
    }

    /// Titre court (« Mot de passe refusé »).
    public var title: String {
        switch self {
        case .wrongPassword: return "Utilisateur ou mot de passe refusé"
        case .passwordExpired: return "Mot de passe à changer"
        case .accountRestricted: return "Compte restreint"
        case .shareNotFound: return "Partage introuvable"
        case .noShares: return "Aucun partage accessible"
        case .protocolVersion: return "Version du protocole refusée"
        case .authMethod: return "Méthode d’identification non prise en charge"
        case .unreachable: return "Serveur injoignable"
        case .timeout: return "Le serveur ne répond pas"
        case .refused: return "Connexion refusée"
        case .accessDenied: return "Accès refusé"
        case .cancelled: return "Montage annulé"
        case .readOnly: return "Partage en lecture seule"
        case .writeDenied: return "Pas de droit d’écriture"
        case .diskFull: return "Partage plein"
        case .other(let code): return "Montage impossible (code \(code))"
        }
    }

    /// Explication et marche à suivre, adaptées au type de partage.
    public func detail(kind: DiskShareKind, server: String, share: String) -> String {
        let proto = kind.label
        let target = share.isEmpty ? server : "\(server)/\(share.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        switch self {
        case .wrongPassword:
            return "\(server) a refusé le compte ou le mot de passe. Vérifiez l’utilisateur (avec le domaine si besoin\u{00A0}: BUREAU;technicien) et retapez le mot de passe dans «\u{00A0}Modifier…\u{00A0}»\u{00A0}; il est gardé au Trousseau."
        case .passwordExpired:
            return "Le serveur demande de changer le mot de passe de ce compte (expiré ou hors de la politique). Changez-le sur le serveur, puis mettez-le à jour dans «\u{00A0}Modifier…\u{00A0}»."
        case .accountRestricted:
            return "Le compte est désactivé, verrouillé ou limité à certaines heures ou certains postes. Vérifiez-le sur le serveur ou dans l’annuaire."
        case .shareNotFound:
            return kind == .nfs
                ? "Le chemin d’export «\u{00A0}\(share)\u{00A0}» n’existe pas sur \(server), ou ce Mac n’est pas autorisé à le monter. Vérifiez la liste des exports (showmount -e \(server))."
                : "«\u{00A0}\(target)\u{00A0}» n’existe pas, ou ce compte ne le voit pas. Vérifiez le nom du partage (ouvrez smb://\(server) dans le Finder pour voir la liste)."
        case .noShares:
            return "\(server) répond, mais ne propose aucun partage à ce compte. Vérifiez les droits du compte sur le NAS."
        case .protocolVersion:
            return kind == .smb
                ? "Le serveur ne parle probablement que SMB1 (vieux NAS, imprimante multifonction, Windows XP), que macOS refuse par sécurité. Activez SMB2 ou SMB3 sur le serveur (réglage «\u{00A0}protocole SMB minimal\u{00A0}» du NAS)."
                : "Le serveur ne propose pas une version de \(proto) que macOS accepte. Vérifiez la version activée sur le serveur (NFS v3 ou v4, AFP 3)."
        case .authMethod:
            return "Le serveur n’accepte aucune des méthodes d’identification de macOS (NTLMv2, Kerberos). Activez NTLMv2 sur le NAS, ou essayez un compte local du NAS."
        case .unreachable:
            return "Aucun chemin réseau vers \(server)\u{00A0}: mauvais VLAN, VPN déconnecté ou appareil éteint. Utilisez «\u{00A0}Tester le serveur\u{00A0}»."
        case .timeout:
            return "\(server) ne répond pas sur le port \(kind.ports().first.map(String.init) ?? "du service")\u{00A0}: service arrêté ou port filtré par un pare-feu. «\u{00A0}Tester le serveur\u{00A0}» montre les ports ouverts."
        case .refused:
            return "\(server) répond, mais refuse la connexion \(proto)\u{00A0}: le service est arrêté ou désactivé sur le NAS."
        case .accessDenied:
            return "Le serveur refuse l’accès à ce partage pour ce compte (ou, en NFS, pour l’adresse de ce Mac)."
        case .cancelled:
            return "Le montage a été annulé avant la fin."
        case .readOnly:
            return "Le partage est monté en lecture seule\u{00A0}: le fichier d’essai ne peut pas y être écrit. Donnez au compte le droit d’écrire, ou choisissez un autre partage."
        case .writeDenied:
            return "Le compte peut lire «\u{00A0}\(target)\u{00A0}» mais pas y écrire. Donnez-lui le droit d’écriture sur le partage, ou choisissez un sous-dossier où il peut écrire."
        case .diskFull:
            return "Il n’y a plus assez de place (ou le quota du compte est atteint) sur «\u{00A0}\(target)\u{00A0}». Choisissez une taille de fichier plus petite."
        case .other(let code):
            let text = code > 0 ? String(cString: strerror(code)) : "erreur NetFS"
            return "macOS n’a pas pu monter «\u{00A0}\(target)\u{00A0}» (\(text)). Essayez de l’ouvrir dans le Finder (Aller › Se connecter au serveur…) pour voir le message complet."
        }
    }

    /// Titre et explication réunis (message d'erreur de l'outil).
    public func message(kind: DiskShareKind, server: String, share: String) -> String {
        title + "\u{00A0}: " + detail(kind: kind, server: server, share: share)
    }

    /// Le mot de passe est en cause (le bouton « Modifier… » est mis en avant).
    public var concernsCredentials: Bool {
        switch self {
        case .wrongPassword, .passwordExpired, .accountRestricted, .authMethod: return true
        default: return false
        }
    }
}
