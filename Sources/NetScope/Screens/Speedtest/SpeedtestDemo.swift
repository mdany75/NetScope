import Foundation
import NetScopeCore

/// Données de démonstration du Speedtest, reprises du croquis (docs/croquis/Speedtest.dc.html).
@MainActor
enum SpeedtestDemo {
    static func apply(to model: SpeedtestModel, now: Date = Date()) {
        let result = SpeedTestSummary(
            downMbps: 912, upMbps: 487, idleLatencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4,
            probesSent: 40, probesLost: 0, streams: 8,
            server: SpeedServerInfo(colo: "YUL", city: "Montréal", country: "CA", clientIP: "203.0.113.24",
                                    asn: 577, asOrganization: "Bell Canada"),
            downloadBytes: 1_140_000_000, uploadBytes: 608_000_000)
        model.loadDemo(result: result, down: curve(912, phase: 2.1), up: curve(487, phase: 1.7),
                       history: history(now: now), lan: lanResult(), lanHost: "10.10.0.20")
    }

    /// Montée en régime exponentielle, comme dans le croquis.
    private static func curve(_ target: Double, phase: Double) -> [SpeedPoint] {
        (0..<50).map { index in
            let t = Double(index + 1) * 0.2
            let value = target * (1 - exp(-t / 1.2)) * (1 + 0.03 * sin(Double(index) * phase))
            return SpeedPoint(time: t, mbps: value)
        }
    }

    private static func history(now: Date) -> [SpeedTestRecord] {
        let server = "Cloudflare · YUL · Montréal"
        func at(_ days: Double, _ hours: Double) -> Date { now.addingTimeInterval(-(days * 86_400 + hours * 3_600)) }
        var records = [
            SpeedTestRecord(date: at(0, 1), kind: .internet, server: server, interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 912, upMbps: 487, latencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4, streams: 8),
            SpeedTestRecord(date: at(0, 2.2), kind: .internet, origin: "planifié", server: server, interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 905, upMbps: 489, latencyMs: 6, loadedLatencyMs: 17, jitterMs: 1.2, streams: 8),
            SpeedTestRecord(date: at(0.8, 0), kind: .lan, server: "NAS 10.10.0.20:5201", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 941, latencyMs: 0.4, streams: 4),
            SpeedTestRecord(date: at(0.8, 0.1), kind: .lan, server: "NAS 10.10.0.20:5201", interfaceName: "en0", interfaceKind: "Wi-Fi",
                            downMbps: 612, latencyMs: 3.1, streams: 4),
            SpeedTestRecord(date: at(0.9, 0), kind: .internet, server: server, interfaceName: "en0", interfaceKind: "Wi-Fi",
                            downMbps: 588, upMbps: 462, latencyMs: 8, loadedLatencyMs: 42, jitterMs: 4.8, streams: 8),
            SpeedTestRecord(date: at(3, 0), kind: .internet, server: "Cloudflare · YYZ · Toronto", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 884, upMbps: 481, latencyMs: 13, loadedLatencyMs: 24, jitterMs: 1.9, streams: 8),
            SpeedTestRecord(date: at(4, 0), kind: .lan, server: "SRV-FICHIERS 10.10.0.12:5201", interfaceName: "en7", interfaceKind: "Ethernet",
                            downMbps: 938, latencyMs: 0.5, streams: 4),
        ]
        // Un test par jour sur 30 jours pour la courbe d'évolution.
        for day in 5..<30 {
            let wobble = sin(Double(day) * 1.3)
            records.append(SpeedTestRecord(
                date: at(Double(day), 2), kind: .internet, origin: day % 3 == 0 ? "planifié" : "manuel", server: server,
                interfaceName: "en7", interfaceKind: "Ethernet", downMbps: 900 + 10 * wobble, upMbps: 485 + 3 * wobble,
                latencyMs: 6 + abs(wobble) * 2, loadedLatencyMs: 18, jitterMs: 1.3 + abs(wobble) * 0.3, streams: 8))
        }
        return records
    }

    private static func lanResult() -> IperfResult {
        let rates: [Double] = [918, 941, 942, 940, 941, 939, 942, 941, 940, 941]
        let retransmits = [12, 0, 0, 3, 0, 0, 1, 0, 0, 0]
        let intervals = rates.enumerated().map { index, rate in
            IperfInterval(start: Double(index), end: Double(index + 1), bytes: Int64(rate * 125_000),
                          bitsPerSecond: rate * 1_000_000, retransmits: retransmits[index])
        }
        return IperfResult(version: "iperf 3.17.1", protocolName: "TCP", streams: 4, duration: 10,
                           localHost: "10.182.122.135", remoteHost: "10.10.0.20", remotePort: 5201,
                           reverse: false, bidirectional: false, intervals: intervals,
                           sentBytes: 1_176_000_000, sentBitsPerSecond: 941_000_000,
                           receivedBytes: 1_174_000_000, receivedBitsPerSecond: 938_500_000, retransmits: 16)
    }
}
