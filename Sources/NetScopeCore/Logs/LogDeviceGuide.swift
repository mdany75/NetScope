import Foundation

// Note 78 (Journaux) : guide de configuration par marque pour envoyer les journaux Syslog des
// équipements vers ce Mac, en UDP ou en TCP (RFC 6587), sur le port de NetScope (5514 par défaut :
// le 514 demande les droits administrateur sur certains Mac). Chaque marque donne les commandes à
// copier, la commande qui vérifie le réglage et une remarque. Texte seul : rien n'est envoyé.

/// Guide de configuration Syslog par marque d'équipement.
public enum LogDeviceGuide {
    public enum Brand: String, CaseIterable, Sendable, Identifiable {
        case fortigate, fortiswitch, cisco, arubaOS, arubaCX, unifi, edgeOS, linux

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .fortigate: return "FortiGate (FortiOS)"
            case .fortiswitch: return "FortiSwitch (FortiSwitchOS)"
            case .cisco: return "Cisco IOS et IOS-XE"
            case .arubaOS: return "HPE Aruba (AOS-S, ProCurve)"
            case .arubaCX: return "HPE Aruba (AOS-CX)"
            case .unifi: return "Ubiquiti UniFi (contrôleur)"
            case .edgeOS: return "Ubiquiti EdgeRouter et EdgeSwitch"
            case .linux: return "Linux (rsyslog)"
            }
        }

        /// Marque regroupée (menu « Marque »).
        public var family: String {
            switch self {
            case .fortigate, .fortiswitch: return "Fortinet"
            case .cisco: return "Cisco"
            case .arubaOS, .arubaCX: return "HP/Aruba"
            case .unifi, .edgeOS: return "Ubiquiti"
            case .linux: return "Autres"
            }
        }

        /// L'équipement sait envoyer en TCP.
        public var supportsTCP: Bool {
            switch self {
            case .unifi, .edgeOS: return false
            default: return true
            }
        }
    }

    /// Une fiche du guide : commandes à copier, vérification et remarque.
    public struct Step: Sendable, Equatable {
        public var brand: Brand
        /// Transport réellement proposé (UDP si la marque ne sait pas faire de TCP).
        public var transport: SyslogTransport
        /// Commandes à saisir (ou chemin dans l'interface web pour UniFi).
        public var commands: String
        /// Les commandes sont un chemin dans une interface web plutôt qu'une console.
        public var isInterfacePath: Bool
        /// Commande qui vérifie le réglage ou envoie un message d'essai.
        public var verify: String?
        public var note: String?
    }

    /// Fiche Syslog d'une marque : `mac` est l'adresse de ce Mac vue par l'équipement.
    public static func syslog(_ brand: Brand, mac: String, port: UInt16, transport requested: SyslogTransport) -> Step {
        let transport: SyslogTransport = brand.supportsTCP ? requested : .udp
        let tcp = transport == .tcp
        switch brand {
        case .fortigate:
            return Step(brand: brand, transport: transport, commands: """
            config log syslogd setting
                set status enable
                set server "\(mac)"
                set port \(port)
                set mode \(tcp ? "reliable" : "udp")
                set format default
            end
            """, isInterfacePath: false,
                        verify: "diagnose log test",
                        note: tcp
                        ? "«\u{00A0}reliable\u{00A0}» envoie en TCP avec le cadrage par longueur (RFC\u{00A0}6587). Les événements à envoyer se choisissent dans «\u{00A0}config log syslogd filter\u{00A0}». «\u{00A0}diagnose log test\u{00A0}» produit des messages d’essai."
                        : "Les événements à envoyer se choisissent dans «\u{00A0}config log syslogd filter\u{00A0}». «\u{00A0}diagnose log test\u{00A0}» produit des messages d’essai. Pour un VDOM\u{00A0}: «\u{00A0}config log syslogd override-setting\u{00A0}».")
        case .fortiswitch:
            return Step(brand: brand, transport: transport, commands: """
            config log syslogd setting
                set status enable
                set server "\(mac)"
                set port \(port)\(tcp ? "\n    set mode reliable" : "")
            end
            """, isInterfacePath: false,
                        verify: "get log syslogd setting",
                        note: "Un FortiSwitch géré par la FortiGate (FortiLink) envoie normalement ses journaux à la FortiGate\u{00A0}: réglez plutôt celle-ci."
                        + (tcp ? " Le mode TCP («\u{00A0}reliable\u{00A0}») dépend de la version de FortiSwitchOS\u{00A0}; s’il est refusé, restez en UDP." : ""))
        case .cisco:
            return Step(brand: brand, transport: transport, commands: """
            configure terminal
             logging host \(mac) transport \(tcp ? "tcp" : "udp") port \(port)
             logging trap informational
             logging origin-id hostname
             service timestamps log datetime msec localtime show-timezone
            end
            write memory
            """, isInterfacePath: false,
                        verify: "show logging | include Trap|\(mac)",
                        note: "«\u{00A0}logging trap\u{00A0}» fixe la gravité minimale envoyée (informational = 6). Sur un équipement à VRF de gestion, ajoutez «\u{00A0}vrf Mgmt-intf\u{00A0}» après l’adresse.")
        case .arubaOS:
            return Step(brand: brand, transport: transport, commands: """
            configure terminal
            logging \(mac) \(tcp ? "tcp" : "udp") \(port)
            logging severity info
            write memory
            """, isInterfacePath: false,
                        verify: "show running-config | include logging",
                        note: "Le TCP demande AOS-S 16.x ou plus récent. Sur un 2530 ou un firmware ancien, seule la forme «\u{00A0}logging \(mac)\u{00A0}» (UDP 514) existe\u{00A0}: changez alors le port de NetScope pour 514.")
        case .arubaCX:
            return Step(brand: brand, transport: transport, commands: """
            configure terminal
            logging \(mac) \(tcp ? "tcp" : "udp") \(port) severity info vrf mgmt
            write memory
            """, isInterfacePath: false,
                        verify: "show logging -r -n 20",
                        note: "Remplacez «\u{00A0}vrf mgmt\u{00A0}» par «\u{00A0}vrf default\u{00A0}» si ce Mac est joint par un port de données plutôt que par le port de gestion.")
        case .unifi:
            return Step(brand: brand, transport: .udp, commands: """
            UniFi Network › Paramètres › Plan de contrôle › Intégrations
              › Journalisation de l’activité (serveur SIEM) : activer
              › Adresse du serveur : \(mac)
              › Port : \(port)
            (anciennes versions : Paramètres › Système › Avancé › Serveur Syslog distant)
            """, isInterfacePath: true,
                        verify: nil,
                        note: "Le contrôleur UniFi n’envoie qu’en UDP\u{00A0}; le réglage s’applique à toutes les bornes et à tous les switchs du site.")
        case .edgeOS:
            return Step(brand: brand, transport: .udp, commands: """
            configure
            set system syslog host \(mac):\(port) facility all level info
            commit
            save
            exit
            """, isInterfacePath: false,
                        verify: "show configuration commands | match syslog",
                        note: "EdgeOS n’envoie qu’en UDP. Sur un EdgeSwitch (FASTPATH)\u{00A0}: «\u{00A0}logging host \(mac) ipv4 \(port) info\u{00A0}» puis «\u{00A0}logging syslog\u{00A0}».")
        case .linux:
            return Step(brand: brand, transport: transport, commands: """
            # /etc/rsyslog.d/90-netscope.conf
            *.* \(tcp ? "@@" : "@")\(mac):\(port)
            # puis :
            sudo systemctl restart rsyslog
            """, isInterfacePath: false,
                        verify: "logger -p user.warning \"Essai NetScope\"",
                        note: tcp ? "«\u{00A0}@@\u{00A0}» envoie en TCP (cadrage par saut de ligne)." : "«\u{00A0}@\u{00A0}» envoie en UDP\u{00A0}; «\u{00A0}@@\u{00A0}» en TCP.")
        }
    }
}
