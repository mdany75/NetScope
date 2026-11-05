import Foundation
import NetScopeCore

/// Démonstration de la note 75 (collecteur de flux de l'écran Trafic) : trois exportateurs fictifs,
/// cohérents avec les appareils de démonstration (DemoData), qui envoient chacun leur format. Les
/// datagrammes sont fabriqués par FlowPacketBuilder et passent par les vrais décodeurs ; rien n'est
/// écouté ni envoyé.
/// - FortiGate du siège (10.182.122.1, NetFlow v9) : le Poste comptabilité (WKS346) envoie une
///   sauvegarde OneDrive qui charge l'envoi du lien Internet (500/50 Mb/s) ; l'appareil inconnu
///   10.182.122.100 télécharge par BitTorrent.
/// - SW-ETG2-01 (10.182.122.3, sFlow v5, 1 paquet sur 1024) : copies SMB du Poste direction vers le
///   serveur de sauvegarde, compteurs de l'interface montante.
/// - Routeur de l'Entrepôt Laval (10.20.0.1, IPFIX) : trafic calme, lien 250/50 Mb/s.
///
/// Captures : NETSCOPE_ECRANS=trafic NETSCOPE_TRAFIC_SOURCE=flux ; NETSCOPE_FLUX_ONGLET=exportateurs,
/// conversations, applications… ; NETSCOPE_TRAFIC_VUE=saturation (feuille « Qui sature le lien ? »).
@MainActor
enum FlowDemo {
    static let fortigate = IPv4Address(10, 182, 122, 1)
    static let switchETG2 = IPv4Address(10, 182, 122, 3)
    static let laval = IPv4Address(10, 20, 0, 1)

    /// La capture demande la source « Flux ».
    static var requestedSource: Bool {
        guard CommandLine.arguments.contains("--snapshot") else { return false }
        return ProcessInfo.processInfo.environment["NETSCOPE_TRAFIC_SOURCE"]?.lowercased().hasPrefix("flux") == true
    }

    static var requestedTab: FlowTab? {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_FLUX_ONGLET"]?.lowercased() else { return nil }
        return raw == "exportateurs" ? .exporters : FlowTab.allCases.first { $0.rawValue == raw }
    }

    /// Fiche du guide montrée par la capture (NETSCOPE_FLUX_MARQUE=arubaOS…).
    static var requestedBrand: FlowDeviceGuide.Brand? {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_FLUX_MARQUE"]?.lowercased() else { return nil }
        return FlowDeviceGuide.Brand.allCases.first { $0.rawValue.lowercased() == raw }
    }

    /// Exportateur montré : la FortiGate du siège (NETSCOPE_FLUX_EXPORTATEUR=tous pour les trois).
    static var requestedExporter: IPv4Address? {
        let raw = CommandLine.arguments.contains("--snapshot") ? ProcessInfo.processInfo.environment["NETSCOPE_FLUX_EXPORTATEUR"]?.lowercased() : nil
        switch raw {
        case "tous": return nil
        case let text?: return IPv4Address(text) ?? fortigate
        case nil: return fortigate
        }
    }

    static let settings: [String: FlowExporterSettings] = [
        fortigate.description: FlowExporterSettings(name: "FortiGate · Siège", wanInterface: 1, downMbps: 500, upMbps: 50),
        switchETG2.description: FlowExporterSettings(name: "SW-ETG2-01 · Siège", wanInterface: nil),
        laval.description: FlowExporterSettings(name: "Routeur · Entrepôt Laval", downMbps: 250, upMbps: 50),
    ]

    /// Un flux fictif : débit en Mb/s dans chaque sens.
    private struct Line {
        var local: String
        var remote: String
        var localPort: UInt16
        var remotePort: UInt16
        var proto: UInt8 = 6
        /// Débit du local vers le distant, et du distant vers le local (Mb/s).
        var upMbps: Double
        var downMbps: Double
        var localIf: UInt16
        var remoteIf: UInt16
        /// Ne tourne que les 25 dernières minutes et vers midi (une sauvegarde).
        var burst = false
    }

    private static let fortigateLines: [Line] = [
        Line(local: "10.182.122.117", remote: "20.190.128.12", localPort: 52_114, remotePort: 443, upMbps: 34.5, downMbps: 0.9, localIf: 5, remoteIf: 1, burst: true),
        Line(local: "10.182.122.117", remote: "52.112.0.5", localPort: 50_012, remotePort: 3478, proto: 17, upMbps: 0.8, downMbps: 1.1, localIf: 5, remoteIf: 1),
        Line(local: "10.182.122.100", remote: "81.171.12.5", localPort: 40_123, remotePort: 6881, upMbps: 2.1, downMbps: 26.4, localIf: 5, remoteIf: 1),
        Line(local: "10.182.122.100", remote: "95.211.8.77", localPort: 40_124, remotePort: 51_413, proto: 17, upMbps: 0.9, downMbps: 3.2, localIf: 5, remoteIf: 1),
        Line(local: "10.182.122.113", remote: "142.250.65.46", localPort: 61_002, remotePort: 443, proto: 17, upMbps: 1.0, downMbps: 15.2, localIf: 5, remoteIf: 1),
        Line(local: "10.182.122.135", remote: "17.253.144.10", localPort: 58_211, remotePort: 443, upMbps: 0.4, downMbps: 5.6, localIf: 7, remoteIf: 1),
        Line(local: "10.182.122.106", remote: "151.101.1.140", localPort: 49_800, remotePort: 443, upMbps: 0.2, downMbps: 4.3, localIf: 5, remoteIf: 1),
        Line(local: "10.10.0.31", remote: "45.60.12.8", localPort: 55_302, remotePort: 443, upMbps: 0.3, downMbps: 2.8, localIf: 9, remoteIf: 1),
        Line(local: "192.168.50.21", remote: "52.36.10.4", localPort: 44_820, remotePort: 443, upMbps: 2.5, downMbps: 0.1, localIf: 11, remoteIf: 1),
        Line(local: "10.182.122.133", remote: "31.13.80.36", localPort: 47_100, remotePort: 443, upMbps: 0.2, downMbps: 1.2, localIf: 7, remoteIf: 1),
        Line(local: "10.182.122.126", remote: "40.108.204.17", localPort: 53_440, remotePort: 443, upMbps: 0.6, downMbps: 3.4, localIf: 5, remoteIf: 1),
        Line(local: "10.10.0.10", remote: "8.8.8.8", localPort: 53_001, remotePort: 53, proto: 17, upMbps: 0.12, downMbps: 0.3, localIf: 9, remoteIf: 1),
        Line(local: "10.182.122.121", remote: "208.73.144.10", localPort: 5060, remotePort: 5060, proto: 17, upMbps: 0.09, downMbps: 0.09, localIf: 5, remoteIf: 1),
        Line(local: "10.182.122.111", remote: "17.57.144.20", localPort: 51_202, remotePort: 443, upMbps: 0.05, downMbps: 0.1, localIf: 5, remoteIf: 1),
    ]

    private static let switchLines: [Line] = [
        Line(local: "10.182.122.126", remote: "10.10.0.31", localPort: 50_440, remotePort: 445, upMbps: 18.5, downMbps: 0.7, localIf: 5, remoteIf: 24, burst: true),
        Line(local: "10.182.122.100", remote: "81.171.12.5", localPort: 40_123, remotePort: 6881, upMbps: 2.1, downMbps: 26.4, localIf: 7, remoteIf: 24),
        Line(local: "10.182.122.113", remote: "142.250.65.46", localPort: 61_002, remotePort: 443, proto: 17, upMbps: 1.0, downMbps: 15.2, localIf: 3, remoteIf: 24),
        Line(local: "10.182.122.113", remote: "10.10.0.10", localPort: 52_002, remotePort: 389, upMbps: 0.1, downMbps: 0.2, localIf: 3, remoteIf: 24),
        Line(local: "10.182.122.106", remote: "151.101.1.140", localPort: 49_800, remotePort: 443, upMbps: 0.2, downMbps: 4.3, localIf: 9, remoteIf: 24),
        Line(local: "10.182.122.126", remote: "10.182.122.111", localPort: 50_901, remotePort: 9100, upMbps: 1.2, downMbps: 0.05, localIf: 5, remoteIf: 14),
        Line(local: "10.182.122.121", remote: "208.73.144.10", localPort: 5060, remotePort: 5060, proto: 17, upMbps: 0.09, downMbps: 0.09, localIf: 10, remoteIf: 24),
    ]

    private static let lavalLines: [Line] = [
        Line(local: "10.20.0.31", remote: "13.107.42.14", localPort: 51_022, remotePort: 443, upMbps: 0.6, downMbps: 3.2, localIf: 2, remoteIf: 1),
        Line(local: "10.20.0.50", remote: "52.96.88.20", localPort: 51_330, remotePort: 443, upMbps: 0.3, downMbps: 0.9, localIf: 2, remoteIf: 1),
        Line(local: "192.168.60.11", remote: "52.36.10.4", localPort: 44_820, remotePort: 443, upMbps: 1.4, downMbps: 0.05, localIf: 3, remoteIf: 1),
        Line(local: "10.20.0.12", remote: "10.10.0.10", localPort: 54_001, remotePort: 445, upMbps: 0.4, downMbps: 1.8, localIf: 2, remoteIf: 4),
        Line(local: "10.20.0.12", remote: "1.1.1.1", localPort: 53_120, remotePort: 53, proto: 17, upMbps: 0.02, downMbps: 0.05, localIf: 2, remoteIf: 1),
    ]

    /// Activité selon l'heure (bureaux de 7 h à 18 h) et pour une sauvegarde.
    private static func activity(_ line: Line, at date: Date, now: Date) -> Double {
        let hour = Calendar.current.component(.hour, from: date)
        let office = (7..<18).contains(hour) ? 1.0 : 0.12
        guard line.burst else { return office }
        if now.timeIntervalSince(date) < 25 * 60 { return 1 }
        return hour == 12 ? 0.8 : 0
    }

    private static func flows(_ lines: [Line], at date: Date, seconds: Double, now: Date, scale: UInt32 = 1) -> [FlowPacketBuilder.Flow] {
        var list: [FlowPacketBuilder.Flow] = []
        // Légère variation d'une minute à l'autre, toujours la même pour une date donnée.
        let wobble = 0.9 + 0.15 * abs(sin(date.timeIntervalSince1970 / 437))
        for line in lines {
            let factor = activity(line, at: date, now: now) * wobble
            guard factor > 0, let local = IPv4Address(line.local), let remote = IPv4Address(line.remote) else { continue }
            let up = UInt32(clamping: Int(line.upMbps * factor * 1_000_000 * seconds / 8) / Int(scale))
            let down = UInt32(clamping: Int(line.downMbps * factor * 1_000_000 * seconds / 8) / Int(scale))
            if up > 0 {
                list.append(FlowPacketBuilder.Flow(source: local, destination: remote, sourcePort: line.localPort, destinationPort: line.remotePort,
                                                   proto: line.proto, bytes: up, packets: max(1, up / 1200), input: line.localIf,
                                                   output: line.remoteIf, durationMs: UInt32(seconds * 1000)))
            }
            if down > 0 {
                list.append(FlowPacketBuilder.Flow(source: remote, destination: local, sourcePort: line.remotePort, destinationPort: line.localPort,
                                                   proto: line.proto, bytes: down, packets: max(1, down / 1200), input: line.remoteIf,
                                                   output: line.localIf, durationMs: UInt32(seconds * 1000)))
            }
        }
        return list
    }

    /// Remplit le collecteur : 24 h de trafic (par tranches de 5 minutes, puis par minute pour la
    /// dernière heure), dans l'ordre chronologique.
    static func feed(_ collector: FlowCollector, now: Date) {
        // Tranches alignées sur les fenêtres du collecteur (minute entière) ; la minute en cours ne
        // porte que les secondes déjà écoulées, comme un vrai exportateur.
        let minuteStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var times: [(Date, Double)] = []
        for step in stride(from: 24 * 12 - 1, to: 12, by: -1) {
            times.append((minuteStart.addingTimeInterval(-Double(step) * 300 + 150), 300))
        }
        for minute in stride(from: 60, through: 1, by: -1) {
            times.append((minuteStart.addingTimeInterval(-Double(minute) * 60 + 30), 60))
        }
        let elapsed = now.timeIntervalSince(minuteStart)
        if elapsed >= 1 { times.append((now.addingTimeInterval(-0.5), elapsed)) }
        var sequence: UInt32 = 1
        var octets: (inbound: UInt64, outbound: UInt64) = (0, 0)
        for (date, seconds) in times {
            sequence &+= 1
            // FortiGate : NetFlow v9, gabarit renvoyé dans chaque datagramme.
            let fg = flows(fortigateLines, at: date, seconds: seconds, now: now)
            collector.ingest(FlowPacketBuilder.netflowV9(fg, sourceID: 1, sequence: sequence), from: fortigate, port: 2055, at: date)
            // Switch : sFlow, 1 paquet sur 1024 (une « trame » représente le volume échantillonné).
            let sw = flows(switchLines, at: date, seconds: seconds, now: now, scale: 1024)
            let uplinkIn = UInt64(sw.filter { $0.input == 24 }.reduce(0) { $0 + UInt64($1.bytes) }) * 1024
            let uplinkOut = UInt64(sw.filter { $0.output == 24 }.reduce(0) { $0 + UInt64($1.bytes) }) * 1024
            octets.inbound &+= uplinkIn + UInt64(seconds * 9_000_000 / 8)
            octets.outbound &+= uplinkOut + UInt64(seconds * 4_000_000 / 8)
            let counters = [FlowPacketBuilder.Counters(ifIndex: 24, speed: 1_000_000_000, inOctets: octets.inbound, outOctets: octets.outbound)]
            collector.ingest(FlowPacketBuilder.sflow(agent: switchETG2, flows: sw, samplingRate: 1024, counters: counters, sequence: sequence),
                             from: switchETG2, port: 6343, at: date)
            // Entrepôt Laval : IPFIX.
            let lv = flows(lavalLines, at: date, seconds: seconds, now: now)
            collector.ingest(FlowPacketBuilder.ipfix(lv, domain: 1, exportTime: UInt32(date.timeIntervalSince1970), sequence: sequence),
                             from: laval, port: 4739, at: date)
        }
        // Un datagramme d'un équipement mal réglé (Syslog envoyé sur le port NetFlow) : rejeté.
        collector.ingest(Array("<134>date=2026-11-05 devname=FGT".utf8), from: IPv4Address(10, 182, 122, 140), port: 2055, at: now.addingTimeInterval(-600))
        collector.forget(exporter: IPv4Address(10, 182, 122, 140))
    }
}
