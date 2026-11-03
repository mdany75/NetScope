import Foundation

/// Fiche d'une adresse MAC : formats, fabricant (table OUI intégrée), type d'adresse.
public struct MACVendorInfo: Sendable, Hashable {
    public struct Format: Sendable, Hashable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var mac: MACAddress
    public var formats: [Format]
    /// Préfixe OUI en majuscules (« 94:DD:F8 »).
    public var oui: String
    /// Fabricant de la table, nil si absent.
    public var vendor: String?
    /// Texte à afficher pour le fabricant.
    public var vendorLabel: String
    /// « Universelle (UAA) » ou « Administrée localement ».
    public var kind: String
    /// « Unicast · attribuée par le fabricant », « Multidiffusion »…
    public var cast: String
}

public enum MACVendorLookup {
    /// Chiffres hexadécimaux de la saisie (pour le message d'erreur « reçu N »).
    public static func hexDigitCount(_ text: String) -> Int {
        text.filter(\.isHexDigit).count
    }

    /// Analyse une MAC dans n'importe quel format accepté par `MACAddress` ; nil si invalide.
    public static func lookup(_ text: String, database: OUIDatabase = .builtIn) -> MACVendorInfo? {
        guard let mac = MACAddress(text) else { return nil }
        return info(for: mac, database: database)
    }

    public static func info(for mac: MACAddress, database: OUIDatabase = .builtIn) -> MACVendorInfo {
        let formats = [
            MACVendorInfo.Format(label: "Deux-points (IEEE)", value: mac.formatted(.upperColon)),
            MACVendorInfo.Format(label: "Tirets (Windows)", value: mac.formatted(.hyphen).uppercased()),
            MACVendorInfo.Format(label: "Points (Cisco)", value: mac.formatted(.cisco)),
            MACVendorInfo.Format(label: "Brut / EUI-48", value: mac.formatted(.bare)),
        ]
        let vendor = database.vendor(for: mac)
        let vendorLabel: String
        if let vendor {
            vendorLabel = vendor
        } else if mac.isBroadcast {
            vendorLabel = "Aucun (adresse de broadcast)"
        } else if mac.isLocallyAdministered {
            vendorLabel = "Aucun (adresse administrée localement)"
        } else {
            vendorLabel = "Inconnu dans la base OUI locale"
        }
        let kind = mac.isLocallyAdministered ? "Administrée localement" : "Universelle (UAA)"
        let cast: String
        if mac.isBroadcast {
            cast = "Broadcast (toutes les stations)"
        } else if mac.isMulticast {
            cast = "Multidiffusion"
        } else if mac.isRandomized {
            cast = "Unicast · probablement une MAC privée aléatoire (iOS, Android, Windows)"
        } else {
            cast = "Unicast · attribuée par le fabricant"
        }
        return MACVendorInfo(mac: mac, formats: formats, oui: mac.oui.uppercased(), vendor: vendor,
                             vendorLabel: vendorLabel, kind: kind, cast: cast)
    }
}
