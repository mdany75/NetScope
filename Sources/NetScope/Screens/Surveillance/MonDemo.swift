import Foundation
import NetScopeCore

/// Données de démonstration de l'écran Surveillance, reprises de docs/croquis/Surveillance.dc.html
/// (state.probes et state.log). Les sondes « DHCP non autorisé » et « Scan complet planifié » du
/// croquis ne sont pas reprises : ces types ne sont pas encore offerts. Aucune sonde ne s'exécute.
@MainActor
enum MonDemo {
    private static let s = "\u{00A0}"

    private struct Row {
        let name: String, kind: MonProbeKind, target: String, sub: String, iv: Int
        let state: MonState, value: String, latency: Double?
        let orange: [Int], red: [Int]
        var dependsOnGateway = true
        var sound = false
        var schedule: MonSchedule = .always
        /// Raison de l'échec d'une sonde en panne (sinon celle de Caméra-Quai).
        var error: String? = nil
        var configure: (inout MonProbe) -> Void = { _ in }
    }

    private static let rows: [Row] = [
        Row(name: "Ping passerelle", kind: .ping, target: "10.182.122.1", sub: "FortiGate-60F", iv: 10, state: .ok,
            value: "1,1\(s)ms · perte 0\(s)%", latency: 1.1, orange: [19], red: [], dependsOnGateway: false, sound: true),
        Row(name: "Caméra-Quai", kind: .ping, target: "192.168.50.21", sub: "Hikvision · VLAN 40", iv: 30, state: .down,
            value: "Aucune réponse", latency: nil, orange: [], red: [21, 22, 23], sound: true,
            configure: { $0.fallbackPort = 554 }),
        Row(name: "Interface imprimante", kind: .http, target: "https://10.182.122.111", sub: "Brother DCP-L2640DW", iv: 60,
            state: .ok, value: "200 OK · 184\(s)ms", latency: 184, orange: [], red: [], schedule: .businessHours,
            configure: { $0.expectedStatus = 200; $0.thresholds.latencyMs = 500 }),
        Row(name: "TCP 443 FortiGate", kind: .tcp, target: "10.182.122.1:443", sub: "FortiGate-60F", iv: 30, state: .ok,
            value: "Ouvert · 2,1\(s)ms", latency: 2.1, orange: [], red: [], dependsOnGateway: false),
        Row(name: "Résolution intranet.local", kind: .dns, target: "intranet.local", sub: "", iv: 60, state: .ok,
            value: "A 10.10.0.10 · 4,0\(s)ms", latency: 4, orange: [], red: [],
            configure: { $0.dnsServer = "10.182.122.1"; $0.dnsExpected = "10.10.0.10" }),
        Row(name: "SW-CORE-01 température", kind: .snmp, target: "10.182.122.2", sub: "Catalyst 9300-48P", iv: 300, state: .ok,
            value: "41\(s)°C", latency: nil, orange: [16], red: [],
            configure: { $0.snmpOID = "1.3.6.1.4.1.9.9.13.1.3.1.3.1008"; $0.snmpComparison = .greater; $0.snmpLimit = 45; $0.snmpUnit = "°C" }),
        Row(name: "Port de WKS346", kind: .switchPort, target: "B0:7B:25:44:A1:6C", sub: "WKS346 · Dell", iv: 300, state: .ok,
            value: "SW-CORE-01 Gi1/0/22", latency: nil, orange: [20], red: [], schedule: .businessHours,
            configure: { $0.expectedLocation = "SW-CORE-01 · Gi1/0/22" }),
        Row(name: "Nouveaux appareils", kind: .newDevices, target: "10.182.122.0/24", sub: "", iv: 900, state: .ok,
            value: "0 nouveau · 182 en ligne", latency: nil, orange: [18], red: [], configure: { $0.knownMACs = [] }),
        Row(name: "Certificat TLS", kind: .http, target: "https://10.182.122.1", sub: "FortiGate-60F", iv: 43_200, state: .warning,
            value: "Expire dans 21\(s)j (24 nov. 2026)", latency: 38, orange: [22, 23], red: [], schedule: .businessHours,
            configure: { $0.certificateDays = 30; $0.thresholds.latencyMs = nil }),
        Row(name: "Wi-Fi AP-ETG2 RSSI", kind: .snmp, target: "10.182.122.104", sub: "FortiAP-231F · AP-ETG2", iv: 60, state: .ok,
            value: "-67\(s)dBm", latency: nil, orange: [17], red: [],
            configure: { $0.snmpOID = "1.3.6.1.4.1.12356.120.1.1.1.0"; $0.snmpComparison = .less; $0.snmpLimit = -75; $0.snmpUnit = "dBm" }),
        Row(name: "Ping SW-ETG2-01", kind: .ping, target: "10.182.122.3", sub: "Aruba 2930F-24G", iv: 30, state: .ok,
            value: "1,6\(s)ms · perte 0\(s)%", latency: 1.6, orange: [], red: []),
        Row(name: "Ping FortiAP-231F", kind: .ping, target: "10.182.122.102", sub: "Gi1/0/12 · VLAN 20", iv: 30, state: .ok,
            value: "2,3\(s)ms · perte 0\(s)%", latency: 2.3, orange: [], red: []),
        // Ressources (note 21) : port saturé d'un switch, processeur d'un serveur, mémoire de ce Mac.
        Row(name: "Uplink SW-ETG2-01 saturé", kind: .portLoad, target: "10.182.122.2", sub: "SW-CORE-01 · Gi1/0/47", iv: 60,
            state: .ok, value: "Gi1/0/47 ↓\(s)241 Mb/s ↑\(s)622 Mb/s · 62\(s)% de 1\(s)Gb/s", latency: nil, orange: [15], red: [],
            configure: { $0.resourcePort = "Gi1/0/47"; $0.resourceLimit = 80; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        Row(name: "Processeur SRV-AD-01", kind: .cpu, target: "10.10.0.10", sub: "Contrôleur de domaine", iv: 60, state: .ok,
            value: "Processeur 22\(s)% · 8 cœurs", latency: nil, orange: [], red: [],
            configure: { $0.resourceLimit = 90; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        Row(name: "Mémoire de ce Mac", kind: .memory, target: "ce Mac", sub: "Macmini-de-Dany", iv: 300, state: .ok,
            value: "Mémoire 68\(s)% · 21,8 Go / 32 Go", latency: nil, orange: [], red: [], dependsOnGateway: false,
            configure: { $0.resourceLimit = 90; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Service en ligne (note 15) : Teams dégradé selon Microsoft.
        Row(name: "Microsoft 365", kind: .onlineService, target: "Microsoft 365", sub: "Outlook · Teams · SharePoint · OneDrive",
            iv: 300, state: .warning, value: "Dégradé · 96\(s)ms", latency: 96, orange: [22, 23], red: [],
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Wi-Fi géré (note 27) : borne FortiAP hors ligne et borne surchargée, lues par la FortiGate.
        Row(name: "FortiAP du Siège", kind: .fortiAPOffline, target: "*", sub: "FortiGate · Siège · 6 bornes", iv: 300, state: .down,
            value: "1 hors ligne sur 6", latency: nil, orange: [], red: [14], dependsOnGateway: false,
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        Row(name: "Charge AP-SALLE-CONF", kind: .fortiAPOverload, target: "AP-SALLE-CONF", sub: "FAP-431F · grande salle", iv: 300,
            state: .warning, value: "18 clients · canal 78\(s)%", latency: nil, orange: [10, 11, 14], red: [], dependsOnGateway: false,
            configure: { $0.wifiThresholds = .standard; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Étendues DHCP (note 37) : le VLAN 20 voix du Siège presque plein.
        Row(name: "Étendues DHCP du Siège", kind: .dhcpScope, target: "*", sub: "FortiGate · Siège · 5 étendues actives", iv: 300,
            state: .warning, value: "5 étendues · max 96\(s)% (VLAN 20)", latency: nil, orange: [12, 13, 14], red: [], dependsOnGateway: false,
            configure: { $0.dhcpThresholds = .standard; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // WAN et VPN (note 39) : tunnel vers Bureau Québec tombé, lien wan2 du Siège dégradé.
        Row(name: "Tunnels VPN du Siège", kind: .vpnTunnel, target: "Siège / *", sub: "FortiGate · Siège · 3 tunnels IPsec", iv: 300,
            state: .down, value: "2 montés sur 3", latency: nil, orange: [], red: [21, 22, 23], dependsOnGateway: false,
            error: "Tunnel VPN-QUEBEC tombé (Vers Bureau Québec, 203.0.113.30)",
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        Row(name: "Liens WAN du Siège", kind: .wanLink, target: "Siège / *", sub: "FortiGate · Siège · wan1, wan2", iv: 300,
            state: .warning, value: "2 actifs sur 2 · 44\(s)ms · perte 4\(s)%", latency: nil, orange: [22, 23], red: [], dependsOnGateway: false,
            configure: { $0.wanThresholds = .standard; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Firmware et licences (note 41) : licence IPS du Siège dans 21 jours, FortiGate et une FortiAP à mettre à jour.
        Row(name: "Licences FortiGuard", kind: .licenseExpiring, target: "*", sub: "FortiGate · Siège, Entrepôt Laval", iv: 3600,
            state: .warning, value: "12 licences · min 21\(s)j", latency: nil, orange: [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23], red: [],
            dependsOnGateway: false,
            configure: { $0.resourceLimit = 30; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        Row(name: "Firmware du parc", kind: .firmwareOutdated, target: "*", sub: "FortiOS, FortiSwitch, FortiAP · 15 équipements", iv: 43_200,
            state: .warning, value: "3 à mettre à jour sur 15", latency: nil, orange: [9, 21], red: [], dependsOnGateway: false,
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        // Trafic (note 54) : envoi du lien wan1 saturé par une sauvegarde OneDrive, menaces bloquées.
        Row(name: "Lien Internet du Siège", kind: .linkSaturated, target: "wan1", sub: "FortiView · Bell Fibre", iv: 300,
            state: .warning, value: "wan1 · 96\(s)%", latency: nil, orange: [13, 14], red: [], dependsOnGateway: false,
            configure: { $0.resourceLimit = 80; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        Row(name: "Nouvelles menaces", kind: .newThreat, target: "*", sub: "FortiView · IPS, antivirus, botnet", iv: 300,
            state: .ok, value: "3 menaces · 3 bloquées", latency: nil, orange: [], red: [], dependsOnGateway: false,
            configure: { $0.knownThreats = []; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Imprimantes (note 91) : toner noir de la HP sous le seuil de 15 %.
        Row(name: "Consommables HP étage 2", kind: .printerSupply, target: "10.182.122.140", sub: "HP LaserJet Pro M404dn · NPI7A4410", iv: 3600,
            state: .warning, value: "Toner noir 9\(s)% · 48\u{202F}213 pages · Toner bas", latency: nil, orange: [10, 11, 12, 13, 14], red: [],
            dependsOnGateway: false,
            configure: { $0.resourceLimit = 15; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Onduleur (note 98) : sur secteur, mais batterie posée en 2021 : à changer.
        Row(name: "Onduleur baie réseau", kind: .upsStatus, target: "10.182.122.160", sub: "APC Smart-UPS 1500 · UPS-BAIE-RESEAU", iv: 300,
            state: .warning, value: "Secteur · batterie 100\(s)% · autonomie 38\(s)min · charge 34\(s)%", latency: nil, orange: [12, 13, 14], red: [],
            dependsOnGateway: false,
            configure: { $0.resourceLimit = 10; $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil) }),
        // Notes 96 et 97 : DHCP pirate, conflits d'IP (passerelle usurpée) et bornes pirates.
        Row(name: "DHCP pirate (bureau)", kind: .rogueDHCP, target: "en0", sub: "DHCPDISCOVER · attendu 10.182.122.1", iv: 900,
            state: .ok, value: "1 attendu · 10.182.122.1", latency: nil, orange: [], red: [], dependsOnGateway: false,
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        Row(name: "Conflits d’adresses IP", kind: .ipConflict, target: "*", sub: "ARP de ce Mac, scans, FortiGate", iv: 600,
            state: .down, value: "2 conflits · 1 MAC instable", latency: nil, orange: [20], red: [21, 22, 23], dependsOnGateway: false,
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
        Row(name: "Bornes Wi-Fi pirates", kind: .rogueAP, target: "*", sub: "FortiAP et balayage de ce Mac", iv: 900,
            state: .down, value: "3 pirates · 6 voisines", latency: nil, orange: [], red: [22, 23], dependsOnGateway: false,
            configure: { $0.thresholds = MonThresholds(latencyMs: nil, lossPercent: nil, failures: 1) }),
    ]

    /// Sonde ouverte dans l'éditeur. Captures : NETSCOPE_SURV_SONDE="Liens WAN du Siège" (ou
    /// « Tunnels VPN du Siège », « Lien Internet du Siège », « Nouvelles menaces ») choisit une autre
    /// sonde que Caméra-Quai ; le tableau la ramène en vue.
    private static var selectedName: String {
        guard CommandLine.arguments.contains("--snapshot"),
              let name = ProcessInfo.processInfo.environment["NETSCOPE_SURV_SONDE"],
              rows.contains(where: { $0.name == name }) else { return "Caméra-Quai" }
        return name
    }

    static func load(into store: MonStore) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int, _ second: Int = 0, dayOffset: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute, second: second), to: today) ?? today
        }
        // Captures : 14 h 32, comme la barre de menus du croquis ; démonstration : l'heure réelle.
        let now = CommandLine.arguments.contains("--snapshot") ? at(14, 32) : Date()
        let currentHour = MonHistory.hourStart(now, calendar: calendar)

        var probes: [MonProbe] = []
        var trackers: [UUID: MonTracker] = [:]
        var history = MonHistory()
        let gatewayID = UUID()
        for (index, row) in rows.enumerated() {
            var probe = MonProbe(id: index == 0 ? gatewayID : UUID(), name: row.name, kind: row.kind, target: row.target,
                                 subtitle: row.sub, interval: row.iv, schedule: row.schedule,
                                 dependsOn: row.dependsOnGateway ? gatewayID : nil, notify: true, sound: row.sound)
            row.configure(&probe)
            probes.append(probe)

            let reachable = row.state != .down
            let result = MonResult(date: now.addingTimeInterval(-Double(row.iv % 50)), reachable: reachable,
                                   latencyMs: row.latency, lossPercent: row.kind == .ping && reachable ? 0 : nil,
                                   value: row.value, error: reachable ? nil : (row.error ?? "aucune réponse ICMP ni TCP 554"))
            let since = row.state == .down ? now.addingTimeInterval(-(2 * 3600 + 4 * 60)) : now.addingTimeInterval(-86_400)
            trackers[probe.id] = MonTracker(state: row.state, consecutiveFailures: row.state == .down ? 248 : 0, since: since,
                                            alerted: row.state == .ok ? nil : row.state, lastResult: result)

            var buckets: [MonHourBucket] = []
            for slot in 0..<MonHistory.hours {
                guard let hour = calendar.date(byAdding: .hour, value: slot - (MonHistory.hours - 1), to: currentHour) else { continue }
                let red = row.red.contains(slot), orange = row.orange.contains(slot)
                buckets.append(MonHourBucket(hour: hour, total: 1, failures: red ? 1 : 0, downs: red ? 1 : 0, warnings: orange ? 1 : 0))
            }
            history.buckets[probe.id.uuidString] = buckets
        }

        func id(_ name: String) -> UUID? { probes.first { $0.name == name }?.id }
        func alert(_ date: Date, _ probe: String, _ severity: MonSeverity, _ message: String, resolvedAt: Date? = nil,
                   resolution: String? = nil, ackAt: Date? = nil) -> MonAlert {
            MonAlert(date: date, probeID: id(probe), probeName: probe, severity: severity, message: message,
                     resolvedAt: resolvedAt, resolution: resolution, acknowledgedAt: ackAt, acknowledgedBy: ackAt == nil ? nil : "Dany")
        }
        var journal = MonJournal(alerts: [
            alert(at(14, 3, 41), "Tunnels VPN du Siège", .critical,
                  "Tunnel VPN-QUEBEC tombé (Vers Bureau Québec, 203.0.113.30)."),
            alert(at(13, 46, 8), "Liens WAN du Siège", .warning,
                  "Lien WAN Vidéotron Câble (wan2) dégradé\(s): perte 4\(s)% (seuil 2\(s)%) vers Google_DNS."),
            alert(at(13, 7, 12), "Microsoft 365", .warning,
                  "Service dégradé\(s): Teams\(s): Retards dans la livraison des messages de conversation (incident TM892341)."),
            alert(at(13, 5, 44), "Certificat TLS", .warning,
                  "Le certificat de https://10.182.122.1 expire le 24 nov. 2026 (dans 21\(s)jours)."),
            alert(at(12, 41, 30), "Étendues DHCP du Siège", .warning,
                  "Étendue VLAN 20 pleine à 96\(s)%\(s): 4 adresses libres\(s); des postes risquent de tomber en 169.254."),
            alert(at(12, 28, 3), "Caméra-Quai", .critical,
                  "192.168.50.21 ne répond plus depuis 3 tentatives (ICMP et TCP 554)."),
            alert(at(11, 47, 20), "Port de WKS346", .warning, "WKS346 vu sur SW-CORE-01 Gi1/0/24 au lieu de Gi1/0/22.",
                  resolvedAt: at(11, 52), resolution: "revenu sur Gi1/0/22 à 11:52", ackAt: at(11, 49)),
            alert(at(10, 15, 2), "Ping passerelle", .warning, "Latence moyenne 63\(s)ms > 50\(s)ms pendant 2\(s)min.",
                  resolvedAt: at(10, 17), resolution: "revenue à 1,1\(s)ms"),
            alert(at(9, 2, 11), "Nouveaux appareils", .info,
                  "Nouvel appareil 10.182.122.133 Android_89UM1WTN (MAC aléatoire D6:4E:81:7A:33:C0).", ackAt: at(9, 10)),
            alert(at(8, 40, 37), "Wi-Fi AP-ETG2 RSSI", .warning,
                  "RSSI moyen -78\(s)dBm < -75\(s)dBm sur AP-ETG2 (10.182.122.104).",
                  resolvedAt: at(8, 45), resolution: "revenu à -67\(s)dBm"),
            alert(at(7, 12, 55), "SW-CORE-01 température", .warning, "Température 46\(s)°C > 45\(s)°C.",
                  resolvedAt: at(7, 40), resolution: "revenue à 41\(s)°C", ackAt: at(7, 30)),
        ])

        // Note 78 : alerte du switch remplacé, suspendue par sa fenêtre de maintenance.
        if let note = MonPlanningDemo.maintenanceNote(probes: probes, now: now) { journal.alerts.insert(note, at: 0) }

        store.loadDemo(probes: probes, trackers: trackers, history: history, journal: journal,
                       selected: id(selectedName), now: now, cycleStart: now.addingTimeInterval(-42))
        // Note 78 : heures ouvrables, maintenance, rappels et historique long (latence, 30 jours).
        MonPlanningDemo.apply(to: store, probes: probes, history: history, now: now)
    }
}
