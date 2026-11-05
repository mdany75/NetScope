import Foundation
import NetScopeCore

/// Note 78 : démonstration du serveur iperf3 intégré (`--demo`) : serveur « à l'écoute » sur le
/// port 5201 (rien n'écoute réellement) et deux tests reçus. Captures : NETSCOPE_OUTIL_DEMO=iperf
/// ouvre l'outil ; NETSCOPE_IPERF_SERVEUR=ecoute montre la vue Serveur, =en-cours un test en cours, =arrete le serveur arrêté.
@MainActor
enum IperfServerDemo {
    static func apply(to model: IperfServerModel, now: Date = Date()) {
        let mode = ProcessInfo.processInfo.environment["NETSCOPE_IPERF_SERVEUR"]
        model.showServer = mode != nil
        let tests = [
            test(client: "10.10.0.48", minutesAgo: 4, reverse: false, streams: 4, mbps: 941.2, now: now),
            test(client: "10.10.0.20", minutesAgo: 9, reverse: true, streams: 1, mbps: 612.8, now: now),
            test(client: "10.182.122.57", minutesAgo: 21, reverse: false, streams: 1, mbps: 287.4, now: now),
        ]
        switch mode {
        case "arrete":
            model.loadDemo(listening: nil, current: nil, tests: tests, stopIn: nil)
        case "en-cours":
            var live = test(client: "10.10.0.52", minutesAgo: 0, reverse: false, streams: 4, mbps: 936, now: now)
            live.intervals = Array(live.intervals.prefix(6))
            live.seconds = 0
            live.bytes = 0
            model.loadDemo(listening: IperfProtocol.defaultPort, current: live, tests: tests, stopIn: 15)
        default:
            model.loadDemo(listening: IperfProtocol.defaultPort, current: nil, tests: tests, stopIn: 11.4)
        }
    }

    /// Test fictif de 10 s avec de petites variations par seconde.
    static func test(client: String, minutesAgo: Double, reverse: Bool, streams: Int, mbps: Double, now: Date) -> IperfServerTest {
        let wobble = [0.97, 1.01, 1.0, 0.99, 1.02, 1.0, 0.98, 1.01, 1.0, 1.02]
        let intervals = wobble.enumerated().map { index, factor in
            IperfInterval(start: Double(index), end: Double(index + 1), bytes: Int64(mbps * factor * 1_000_000 / 8),
                          bitsPerSecond: mbps * factor * 1_000_000)
        }
        let bytes = intervals.reduce(Int64(0)) { $0 + $1.bytes }
        return IperfServerTest(client: client, date: now.addingTimeInterval(-minutesAgo * 60), reverse: reverse, streams: streams,
                               requestedSeconds: 10, seconds: 10, bytes: bytes, clientBytes: bytes + 262_144,
                               intervals: intervals, clientVersion: "3.17.1")
    }
}
