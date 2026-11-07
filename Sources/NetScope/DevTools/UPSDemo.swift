import Foundation
import NetScopeCore

/// Note 98 : relevé de démonstration (`--demo`) de l'onduleur de la baie réseau, passé par le même
/// analyseur que les vraies réponses SNMP (aucun réseau). Sur secteur, autonomie de 38 min, mais
/// batterie posée en mars 2021 : à changer (plus de quatre ans).
/// Captures : NETSCOPE_DEVICE=10.182.122.160 montre la carte « Onduleur » de la fiche ;
/// NETSCOPE_INV_VUE=onduleurs la vue « Onduleurs » de l'Inventaire.
enum UPSDemo {
    static let mac = "00:C0:B7:5E:21:A0"

    static func readings(now: Date = Date()) -> [String: UPSReading] {
        guard let key = MACAddress(mac)?.description,
              let reading = UPSMIB.reading(binds(), now: now.addingTimeInterval(-900)) else { return [:] }
        return [key: reading]
    }

    /// Réponses UPS-MIB et PowerNet d'un APC Smart-UPS 1500 (carte AP9641).
    static func binds() -> [SNMPVarBind] {
        func int(_ oid: String, _ value: Int64) -> SNMPVarBind { SNMPVarBind(oid: SNMPOID(oid)!, value: .integer(value)) }
        func text(_ oid: String, _ value: String) -> SNMPVarBind { SNMPVarBind(oid: SNMPOID(oid)!, value: .octetString(Array(value.utf8))) }
        return [
            text("1.3.6.1.2.1.33.1.1.1.0", "APC"),
            text("1.3.6.1.2.1.33.1.1.2.0", "Smart-UPS 1500"),
            int("1.3.6.1.2.1.33.1.2.1.0", 2),
            int("1.3.6.1.2.1.33.1.2.2.0", 0),
            int("1.3.6.1.2.1.33.1.2.3.0", 38),
            int("1.3.6.1.2.1.33.1.2.4.0", 100),
            int("1.3.6.1.2.1.33.1.2.7.0", 26),
            int("1.3.6.1.2.1.33.1.3.3.1.3.1", 121),
            int("1.3.6.1.2.1.33.1.4.1.0", 3),
            int("1.3.6.1.2.1.33.1.4.4.1.2.1", 120),
            int("1.3.6.1.2.1.33.1.4.4.1.5.1", 34),
            int("1.3.6.1.2.1.33.1.7.3.0", 1),
            text("1.3.6.1.4.1.318.1.1.1.2.1.3.0", "03/18/21"),
            int("1.3.6.1.4.1.318.1.1.1.2.2.4.0", 1),
            text("1.3.6.1.4.1.318.1.1.1.7.2.4.0", "10/20/2026"),
        ]
    }
}
