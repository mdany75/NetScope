import Foundation

// Note 75 : guide de configuration par marque pour envoyer les flux d'un équipement vers ce Mac
// (NetFlow v9, IPFIX ou sFlow), sur les ports du collecteur de NetScope. Chaque fiche donne les
// commandes à copier, la commande qui vérifie le réglage et une remarque. Texte seul : rien n'est
// envoyé. Les commandes suivent la documentation publiée par chaque fabricant ; les noms
// d'interface (wan1, GigabitEthernet0/0/0, ether1…) sont des exemples à adapter.

public enum FlowDeviceGuide {
    public enum Brand: String, CaseIterable, Sendable, Identifiable {
        case fortigate, fortiswitch, ciscoNetFlow, ciscoIPFIX, arubaOS, arubaCX, mikrotik, edgeRouter, unifi

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .fortigate: return "FortiGate (FortiOS) · NetFlow\u{00A0}v9"
            case .fortiswitch: return "FortiSwitch · sFlow"
            case .ciscoNetFlow: return "Cisco IOS-XE · NetFlow\u{00A0}v9"
            case .ciscoIPFIX: return "Cisco IOS-XE · IPFIX"
            case .arubaOS: return "HPE Aruba AOS-S (ProCurve) · sFlow"
            case .arubaCX: return "HPE Aruba AOS-CX · sFlow"
            case .mikrotik: return "MikroTik RouterOS · NetFlow\u{00A0}v9 ou IPFIX"
            case .edgeRouter: return "Ubiquiti EdgeRouter · NetFlow\u{00A0}v9"
            case .unifi: return "Ubiquiti UniFi · NetFlow"
            }
        }

        /// Marque regroupée (menu « Équipement »).
        public var family: String {
            switch self {
            case .fortigate, .fortiswitch: return "Fortinet"
            case .ciscoNetFlow, .ciscoIPFIX: return "Cisco"
            case .arubaOS, .arubaCX: return "HP/Aruba"
            case .mikrotik: return "MikroTik"
            case .edgeRouter, .unifi: return "Ubiquiti"
            }
        }

        /// Format envoyé par cette fiche.
        public var kind: FlowProtocolKind {
            switch self {
            case .fortigate, .ciscoNetFlow, .edgeRouter, .unifi, .mikrotik: return .netflow9
            case .ciscoIPFIX: return .ipfix
            case .fortiswitch, .arubaOS, .arubaCX: return .sflow
            }
        }

        public static let families = ["Fortinet", "Cisco", "HP/Aruba", "MikroTik", "Ubiquiti"]
    }

    /// Une fiche du guide.
    public struct Step: Sendable, Equatable {
        public var brand: Brand
        public var kind: FlowProtocolKind
        public var port: UInt16
        public var commands: String
        /// Les commandes sont un chemin dans une interface web.
        public var isInterfacePath: Bool
        public var verify: String?
        public var note: String?
    }

    /// Port du collecteur qui reçoit ce format.
    public static func port(for kind: FlowProtocolKind, ports: FlowCollectorPorts) -> UInt16 {
        switch kind {
        case .netflow5, .netflow9: return ports.netflow
        case .ipfix: return ports.ipfix
        case .sflow: return ports.sflow
        }
    }

    /// Fiche d'un équipement, pointant vers `mac` (adresse IPv4 de ce Mac).
    public static func step(_ brand: Brand, mac: String, ports: FlowCollectorPorts) -> Step {
        let port = port(for: brand.kind, ports: ports)
        switch brand {
        case .fortigate:
            return Step(brand: brand, kind: .netflow9, port: port, commands: """
            config system netflow
                config collectors
                    edit 1
                        set collector-ip \(mac)
                        set collector-port \(port)
                    next
                end
            end
            config system interface
                edit "wan1"
                    set netflow-sampler both
                next
            end
            """, isInterfacePath: false, verify: "get system netflow",
            note: "FortiOS 7.2 et plus. Sur FortiOS 7.0 et avant, pas de bloc «\u{00A0}config collectors\u{00A0}»\u{00A0}: «\u{00A0}set collector-ip\u{00A0}» et «\u{00A0}set collector-port\u{00A0}» directement sous «\u{00A0}config system netflow\u{00A0}». Activez «\u{00A0}netflow-sampler\u{00A0}» sur le lien WAN et sur les interfaces internes à observer\u{00A0}; FortiView reste plus détaillé (applications reconnues).")
        case .fortiswitch:
            return Step(brand: brand, kind: .sflow, port: port, commands: """
            config system sflow
                set collector-ip \(mac)
                set collector-port \(port)
            end
            config switch interface
                edit "port1"
                    set sflow-sampler enabled
                    set sflow-sample-rate 512
                    set sflow-counter-interval 30
                next
            end
            """, isInterfacePath: false, verify: "get system sflow",
            note: "Commandes de la console du FortiSwitch (mode autonome). Un FortiSwitch géré par la FortiGate (FortiLink) se règle depuis la FortiGate\u{00A0}: le trafic y est déjà vu par FortiView.")
        case .ciscoNetFlow, .ciscoIPFIX:
            let ipfix = brand == .ciscoIPFIX
            return Step(brand: brand, kind: brand.kind, port: port, commands: """
            flow record NETSCOPE-REC
             match ipv4 source address
             match ipv4 destination address
             match ipv4 protocol
             match transport source-port
             match transport destination-port
             match interface input
             collect interface output
             collect counter bytes long
             collect counter packets long
             collect timestamp sys-uptime first
             collect timestamp sys-uptime last
            flow exporter NETSCOPE
             destination \(mac)
             transport udp \(port)
             export-protocol \(ipfix ? "ipfix" : "netflow-v9")
             template data timeout 60
            flow monitor NETSCOPE-MON
             exporter NETSCOPE
             record NETSCOPE-REC
             cache timeout active 60
            interface GigabitEthernet0/0/0
             ip flow monitor NETSCOPE-MON input
             ip flow monitor NETSCOPE-MON output
            """, isInterfacePath: false, verify: "show flow exporter NETSCOPE statistics",
            note: "Flexible NetFlow (IOS-XE, ISR et Catalyst). «\u{00A0}template data timeout 60\u{00A0}»\u{00A0}: le gabarit est renvoyé chaque minute, les premiers flux reçus avant lui sont gardés de côté puis décodés.")
        case .arubaOS:
            return Step(brand: brand, kind: .sflow, port: port, commands: """
            sflow 1 destination \(mac) \(port)
            sflow 1 sampling 1-24 512
            sflow 1 polling 1-24 30
            write memory
            """, isInterfacePath: false, verify: "show sflow 1 destination",
            note: "Remplacez «\u{00A0}1-24\u{00A0}» par les ports à observer (le port vers le routeur suffit pour le lien Internet). Taux 512\u{00A0}: un paquet sur 512, volumes estimés.")
        case .arubaCX:
            return Step(brand: brand, kind: .sflow, port: port, commands: """
            sflow
            sflow collector \(mac) port \(port) vrf default
            sflow sampling 4096
            sflow polling 30
            interface 1/1/1
                sflow
            """, isInterfacePath: false, verify: "show sflow",
            note: "Sur AOS-CX, «\u{00A0}vrf mgmt\u{00A0}» si le Mac est joint par le port de gestion.")
        case .mikrotik:
            return Step(brand: brand, kind: .netflow9, port: port, commands: """
            /ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m
            /ip traffic-flow target add dst-address=\(mac) port=\(port) version=9
            """, isInterfacePath: false, verify: "/ip traffic-flow target print",
            note: "IPFIX\u{00A0}: «\u{00A0}version=ipfix port=\(ports.ipfix)\u{00A0}». Traffic Flow de RouterOS est compatible NetFlow v5, v9 et IPFIX.")
        case .edgeRouter:
            return Step(brand: brand, kind: .netflow9, port: port, commands: """
            configure
            set system flow-accounting interface eth0
            set system flow-accounting netflow version 9
            set system flow-accounting netflow server \(mac) port \(port)
            set system flow-accounting netflow timeout expiry-interval 60
            commit ; save
            """, isInterfacePath: false, verify: "show flow-accounting",
            note: "eth0\u{00A0}: l'interface WAN (ajoutez une ligne par interface à observer).")
        case .unifi:
            return Step(brand: brand, kind: .netflow9, port: port, commands: """
            UniFi Network › Réglages › Passerelle (ou Contrôle du trafic) › NetFlow
            Serveur : \(mac)
            Port : \(port)
            Version : 9
            """, isInterfacePath: true, verify: nil,
            note: "Le menu change d'une version de UniFi Network à l'autre et certaines passerelles ne proposent pas NetFlow\u{00A0}; vérifiez la note de version de votre console.")
        }
    }
}
