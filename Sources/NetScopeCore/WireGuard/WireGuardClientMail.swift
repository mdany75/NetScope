import Foundation

// Note 106 : tunnel d'un client de wg-easy (AllowedIPs) et courriel de mise en service. Rien n'est
// envoyé ici : l'application ouvre un brouillon, que le technicien relit et envoie lui-même.

/// Réseaux qui passent dans le tunnel d'un client (AllowedIPs de son fichier .conf).
public enum WireGuardTunnel {
    /// Tout le trafic du client passe par le VPN.
    public static let fullTunnel = ["0.0.0.0/0", "::/0"]

    /// Liste saisie (virgules, points-virgules, espaces ou retours à la ligne) : adresses en notation
    /// CIDR, sans doublon ; une adresse seule devient /32 ou /128. `invalid` : ce qui n'est pas lisible.
    public static func parse(_ text: String) -> (addresses: [String], invalid: [String]) {
        var addresses: [String] = []
        var invalid: [String] = []
        let parts = text.split { ",; \n\t\r".contains($0) }.map(String.init)
        for part in parts {
            guard let clean = normalized(part) else {
                invalid.append(part)
                continue
            }
            if !addresses.contains(clean) { addresses.append(clean) }
        }
        return (addresses, invalid)
    }

    private static func normalized(_ text: String) -> String? {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count <= 2, let host = pieces.first, !host.isEmpty else { return nil }
        let isV4 = IPv4Address(host) != nil
        let isV6 = !isV4 && IPv6Address(host) != nil
        guard isV4 || isV6 else { return nil }
        let maximum = isV4 ? 32 : 128
        guard pieces.count == 2 else { return "\(host)/\(maximum)" }
        guard !pieces[1].isEmpty, pieces[1].allSatisfy(\.isNumber), let prefix = Int(pieces[1]), (0...maximum).contains(prefix) else { return nil }
        return "\(host)/\(prefix)"
    }

    /// Keepalive saisi, en secondes : vide donne nil (inchangé), 0 le désactive. `valid` : 0 à 65535.
    public static func parseKeepalive(_ text: String) -> (valid: Bool, seconds: Int?) {
        let clean = text.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return (true, nil) }
        guard clean.allSatisfy(\.isNumber), let value = Int(clean), (0...65_535).contains(value) else { return (false, nil) }
        return (true, value)
    }

    /// « Tout le trafic », « Réglage du serveur » ou la liste.
    public static func label(_ allowed: [String]?) -> String {
        guard let allowed else { return "Réglage du serveur" }
        return Set(allowed) == Set(fullTunnel) ? "Tout le trafic" : allowed.joined(separator: ", ")
    }
}

/// Courriel envoyé au client : liens du logiciel officiel et fichier du tunnel en pièce jointe.
public enum WireGuardClientMail {
    public struct Download: Equatable, Sendable {
        public var platform: String
        public var url: String
    }

    /// Liens officiels, repris de wireguard.com/install.
    public static let downloads = [
        Download(platform: "Windows", url: "https://download.wireguard.com/windows-client/wireguard-installer.exe"),
        Download(platform: "macOS", url: "https://apps.apple.com/app/wireguard/id1451685025"),
        Download(platform: "iPhone et iPad", url: "https://apps.apple.com/app/wireguard/id1441195209"),
        Download(platform: "Android", url: "https://play.google.com/store/apps/details?id=com.wireguard.android"),
    ]

    /// Nom du fichier joint. WireGuard en tire le nom du tunnel : 15 caractères au plus, parmi
    /// lettres et chiffres sans accent, « _ = + . - ».
    public static func fileName(for client: String) -> String {
        let folded = client.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_CA"))
        var slug = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber || "_=+.-".contains(character) {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(15))
        while let last = slug.last, "-.".contains(last) { slug.removeLast() }
        return (slug.isEmpty ? "vpn" : slug) + ".conf"
    }

    /// Une seule adresse, sans espace ni caractère de contrôle.
    public static func isValidRecipient(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        // Aucun séparateur, ni caractère invisible ou d'inversion (l'adresse affichée doit être la vraie).
        let refused = CharacterSet.controlCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: ",;<>\"()[]\\"))
        return text.trimmingCharacters(in: .whitespaces).unicodeScalars.allSatisfy { !refused.contains($0) }
    }

    public static func subject(client: String) -> String {
        "Votre accès VPN\u{00A0}: \(client)"
    }

    /// Nom de l'image du code QR, à côté du fichier du tunnel.
    public static func qrFileName(for confFile: String) -> String {
        (confFile.hasSuffix(".conf") ? String(confFile.dropLast(5)) : confFile) + "-QR.png"
    }

    public static func body(client: String, fileName: String, qrFile: String? = nil) -> String {
        let phone = qrFile.map { "Sur un téléphone, vous pouvez aussi ajouter le tunnel en scannant le code QR joint (\($0)) depuis l’application.\n\n" } ?? ""
        let links = downloads.map { "   \($0.platform)\u{00A0}: \($0.url)" }.joined(separator: "\n")
        return """
        Bonjour,

        Voici votre accès VPN «\u{00A0}\(client)\u{00A0}».

        1. Installez l’application WireGuard\u{00A0}:
        \(links)

        2. Ouvrez WireGuard, choisissez d’importer un tunnel depuis un fichier, puis sélectionnez le fichier joint à ce courriel (\(fileName)).

        \(phone)3. Activez le tunnel.

        Ces pièces jointes contiennent votre clé personnelle\u{00A0}: ne les transférez à personne et supprimez ce courriel une fois le tunnel importé.

        """
    }
}
