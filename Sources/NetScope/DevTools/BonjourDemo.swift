import Foundation
import NetScopeCore

/// Navigateur Bonjour en démonstration (note 118) : services fictifs, aucun paquet envoyé.
/// Captures : NETSCOPE_OUTIL_DEMO=bonjour ouvre l'outil ; NETSCOPE_BONJOUR_DEMO=vide montre
/// l'état initial, =aucun une recherche sans résultat, =refus l'autorisation Réseau local manquante,
/// =type le regroupement par type.
enum BonjourDemo {
    static let services: [BonjourService] = {
        let printer = "imprimante-rdc.local."
        let nas = "nas-bureau.local."
        let mac = "mac-comptoir.local."
        let tv = "ecran-salle-a.local."
        let printerTXT = ["ty": "Laser Exemple 5200", "rp": "ipp/print", "pdl": "application/pdf,image/urf",
                          "adminurl": "http://imprimante-rdc.local./", "Color": "F", "Duplex": "T", "note": "Rez-de-chaussée"]
        return [
            BonjourService(type: "_ipp._tcp", instance: "Imprimante du rez-de-chaussée", host: printer, port: 631,
                           ipv4: ["10.182.122.40"], ipv6: ["fe80::2a0:deff:fe12:3456"], txt: printerTXT),
            BonjourService(type: "_ipps._tcp", instance: "Imprimante du rez-de-chaussée", host: printer, port: 631,
                           ipv4: ["10.182.122.40"], ipv6: ["fe80::2a0:deff:fe12:3456"], txt: printerTXT),
            BonjourService(type: "_pdl-datastream._tcp", instance: "Imprimante du rez-de-chaussée", host: printer, port: 9100,
                           ipv4: ["10.182.122.40"], txt: ["ty": "Laser Exemple 5200"]),
            BonjourService(type: "_uscan._tcp", instance: "Imprimante du rez-de-chaussée", host: printer, port: 80,
                           ipv4: ["10.182.122.40"], txt: ["rs": "eSCL", "vers": "2.63"]),
            BonjourService(type: "_http._tcp", instance: "Imprimante du rez-de-chaussée", host: printer, port: 80,
                           ipv4: ["10.182.122.40"], txt: ["path": "/"]),
            BonjourService(type: "_smb._tcp", instance: "NAS-BUREAU", host: nas, port: 445, ipv4: ["10.182.122.15"]),
            BonjourService(type: "_afpovertcp._tcp", instance: "NAS-BUREAU", host: nas, port: 548, ipv4: ["10.182.122.15"]),
            BonjourService(type: "_adisk._tcp", instance: "NAS-BUREAU", host: nas, port: 9,
                           ipv4: ["10.182.122.15"], txt: ["sys": "waMa=0,adVF=0x100", "dk0": "adVN=Sauvegardes,adVF=0x82"]),
            BonjourService(type: "_ssh._tcp", instance: "NAS-BUREAU", host: nas, port: 22, ipv4: ["10.182.122.15"]),
            BonjourService(type: "_device-info._tcp", instance: "NAS-BUREAU", host: nas, port: 0, ipv4: ["10.182.122.15"], txt: ["model": "Xserve"]),
            BonjourService(type: "_rfb._tcp", instance: "Mac du comptoir", host: mac, port: 5900,
                           ipv4: ["10.182.122.61"], ipv6: ["fd12:3456:789a::61"]),
            BonjourService(type: "_smb._tcp", instance: "Mac du comptoir", host: mac, port: 445, ipv4: ["10.182.122.61"]),
            BonjourService(type: "_companion-link._tcp", instance: "Mac du comptoir", host: mac, port: 49152,
                           ipv4: ["10.182.122.61"], txt: ["rpFl": "0x20000", "rpVr": "510.1"]),
            BonjourService(type: "_airplay._tcp", instance: "Écran de la salle A", host: tv, port: 7000,
                           ipv4: ["10.182.122.77"], txt: ["model": "AppleTV14,1", "srcvers": "770.8.1", "features": "0x4A7FCA00,0xBC354BD0"]),
            BonjourService(type: "_raop._tcp", instance: "02AABB112233@Écran de la salle A", host: tv, port: 7000,
                           ipv4: ["10.182.122.77"], txt: ["am": "AppleTV14,1", "tp": "UDP"]),
            BonjourService(type: "_sleep-proxy._udp", instance: "70-35-60-63.1 Écran de la salle A", host: tv, port: 62000, ipv4: ["10.182.122.77"]),
            BonjourService(type: "_vendeur-exemple._tcp", instance: "Capteur de température", host: "capteur-02.local.", port: 8883,
                           ipv4: ["10.182.122.102"], txt: ["fw": "1.4.2"]),
            BonjourService(type: "_googlecast._tcp", instance: "Téléviseur de la cafétéria"),
        ]
    }()

    static var selectedID: String { services[0].id }
}
