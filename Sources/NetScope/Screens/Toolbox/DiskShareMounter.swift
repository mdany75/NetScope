import Foundation
import NetFS
import NetScopeCore

/// Montage et démontage des partages enregistrés (note 55), par NetFS : dans l'app, car
/// NetScopeCore n'importe que Foundation, Network et Darwin. Aucune fenêtre de macOS (NoUI) : une
/// erreur revient en `DiskShareProblem` expliqué. Jamais appelé en démonstration ni pendant les
/// captures ni dans les tests.
enum DiskShareMounter {
    /// Partage prêt à mesurer.
    struct Mounted: Sendable {
        let path: String
        /// NetScope l'a monté pour le test : il le démonte à la fin (jamais un partage déjà monté).
        let mountedByNetScope: Bool
    }

    enum Outcome: Sendable {
        case mounted(Mounted)
        case failed(DiskShareProblem)
    }

    static let keychain = UpdKeychain(service: DiskShareLocation.keychainService)

    /// Point de montage d'un partage déjà monté (Finder, autre app, test précédent), s'il y en a un.
    static func alreadyMounted(_ share: DiskShareLocation) -> String? {
        let volumes = DiskLocationCatalog.mountedVolumes().compactMap { DiskLocationCatalog.location(for: $0) }
        return volumes.first { DiskShareCatalog.matches(share, mounted: $0) }?.path
    }

    /// Monte le partage s'il ne l'est pas déjà. Bloquant : appelé hors du fil principal.
    static func mount(_ share: DiskShareLocation) -> Outcome {
        if let path = alreadyMounted(share) { return .mounted(Mounted(path: path, mountedByNetScope: false)) }
        guard let url = share.mountURL else { return .failed(.shareNotFound) }
        let open = NSMutableDictionary()
        // Pas de fenêtre d'identification de macOS : le mot de passe vient du Trousseau.
        open["UIOption"] = "NoUI"
        let user = share.kind.usesCredentials && !share.trimmedUser.isEmpty ? share.trimmedUser : nil
        if share.kind.usesCredentials && user == nil { open["Guest"] = true }
        let password = user != nil && share.hasPassword ? keychain.string(for: share.keychainAccount) : nil
        let options = NSMutableDictionary()
        // Montage discret : ni sur le bureau ni dans la barre latérale du Finder pendant le test.
        options["MountFlags"] = NSNumber(value: Int32(MNT_DONTBROWSE))
        options["SoftMount"] = true
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?, open, options, &mountpoints)
        let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
        if status == 0, let path = paths.first {
            return .mounted(Mounted(path: path, mountedByNetScope: true))
        }
        if status == EEXIST, let path = alreadyMounted(share) ?? paths.first {
            return .mounted(Mounted(path: path, mountedByNetScope: false))
        }
        return .failed(DiskShareProblem.mount(code: status) ?? .other(status))
    }

    /// Démonte un partage monté par NetScope ; quelques essais (le nettoyage du fichier d'essai
    /// peut finir juste après l'arrêt du test). Vrai si le partage n'est plus monté.
    static func unmount(path: String) async -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        for attempt in 0..<4 {
            do {
                try await FileManager.default.unmountVolume(at: url, options: [.withoutUI])
                return true
            } catch {
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        return false
    }

    /// Essai d'écriture d'un tout petit fichier : droit d'écriture refusé, lecture seule ou partage
    /// plein expliqués avant de lancer le test (nil : on peut écrire).
    static func writeProblem(at path: String) -> DiskShareProblem? {
        let probe = (path as NSString).appendingPathComponent(".netscope-ecriture-\(UUID().uuidString.prefix(8))")
        let fd = Darwin.open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return DiskShareProblem.write(errno: errno) }
        var byte: UInt8 = 0x4E
        let written = Darwin.write(fd, &byte, 1)
        let code = errno
        close(fd)
        unlink(probe)
        return written == 1 ? nil : DiskShareProblem.write(errno: code)
    }
}
