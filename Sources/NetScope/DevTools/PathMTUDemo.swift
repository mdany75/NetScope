import Foundation
import NetScopeCore

/// Test MTU en démonstration (--demo) et en capture (--snapshot) : chemins simulés, aucun paquet
/// envoyé. La recherche est la vraie (PathMTUSearch) ; seule la sonde est simulée.
/// NETSCOPE_MTU_DEMO=ipsec (tunnel sans message ICMP) ou jumbo choisit le scénario affiché.
enum PathMTUDemo {
    struct Scenario {
        let target: String
        let address: IPv4Address
        let mtu: Int
        let interfaceMTU: Int
        /// Les routeurs renvoient « fragmentation nécessaire » (sinon : trou noir).
        let sendsICMP: Bool
        let router: IPv4Address?
        let baseRTT: Double
        let jumbo: Bool
    }

    static let pppoe = Scenario(target: "1.1.1.1", address: IPv4Address(1, 1, 1, 1), mtu: 1492, interfaceMTU: 1500,
                                sendsICMP: true, router: IPv4Address(100, 64, 0, 1), baseRTT: 11.8, jumbo: false)
    static let ipsec = Scenario(target: "10.20.0.10", address: IPv4Address(10, 20, 0, 10), mtu: 1438, interfaceMTU: 1500,
                                sendsICMP: false, router: nil, baseRTT: 8.6, jumbo: false)
    static let jumbo = Scenario(target: "10.182.122.30", address: IPv4Address(10, 182, 122, 30), mtu: 9000, interfaceMTU: 9000,
                                sendsICMP: true, router: nil, baseRTT: 0.4, jumbo: true)

    /// Scénario affiché à l'ouverture.
    static var initial: Scenario {
        switch ProcessInfo.processInfo.environment["NETSCOPE_MTU_DEMO"] {
        case "ipsec": return ipsec
        case "jumbo": return jumbo
        default: return pppoe
        }
    }

    /// Scénario d'une cible saisie en démonstration : les cibles connues gardent le leur, les
    /// adresses privées passent en Ethernet standard, Internet en PPPoE.
    static func scenario(for target: String, address: IPv4Address) -> Scenario {
        if let known = [pppoe, ipsec, jumbo].first(where: { $0.address == address }) { return known }
        if address.description.hasPrefix("10.20.") || address.description.hasPrefix("10.30.") {
            return Scenario(target: target, address: address, mtu: 1438, interfaceMTU: 1500, sendsICMP: false, router: nil,
                            baseRTT: 9.1, jumbo: false)
        }
        let local = AddressScope.of(address) == .privee
        return Scenario(target: target, address: address, mtu: local ? 1500 : 1492, interfaceMTU: 1500, sendsICMP: true,
                        router: local ? nil : IPv4Address(100, 64, 0, 1), baseRTT: local ? 2.4 : 14.2, jumbo: false)
    }

    /// Sonde simulée : réponse, refus local, « fragmentation nécessaire » ou silence (trou noir).
    static func probe(_ scenario: Scenario, size: Int) -> PathMTUOutcome {
        if size > scenario.interfaceMTU { return .tooBig(reportedMTU: nil, from: nil, local: true) }
        if size <= scenario.mtu {
            let jitter = Double((size * 7919) % 17) / 10
            return .reply(rttMs: ((scenario.baseRTT + Double(size) / 4000 + jitter / 4) * 10).rounded() / 10)
        }
        return scenario.sendsICMP ? .tooBig(reportedMTU: scenario.mtu, from: scenario.router, local: false) : .lost
    }

    static func options(_ scenario: Scenario) -> PathMTUOptions {
        PathMTUOptions(maxSize: scenario.jumbo ? PathMTUOptions.jumboSize : 1500, attempts: 2, timeout: 1.5,
                       interfaceMTU: scenario.interfaceMTU)
    }

    /// Historique des mesures (les plus récentes d'abord).
    static func history(now: Date = Date()) -> [PathMTUMeasurement] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            PathMTUMeasurement(date: ago(3), target: "1.1.1.1", address: "1.1.1.1", mtu: 1492, maxTested: 1500, kind: .pppoe,
                               probes: 3, blackHole: false, method: .socket),
            PathMTUMeasurement(date: ago(26), target: "10.20.0.10", address: "10.20.0.10", mtu: 1438, maxTested: 1500, kind: .ipsec,
                               probes: 17, blackHole: true, method: .socket),
            PathMTUMeasurement(date: ago(41), target: "10.182.122.30", address: "10.182.122.30", mtu: 9000, maxTested: 9000,
                               kind: .jumbo, probes: 2, blackHole: false, method: .socket),
            PathMTUMeasurement(date: ago(58), target: "10.182.122.1", address: "10.182.122.1", mtu: 1500, maxTested: 1500,
                               kind: .standard, probes: 2, blackHole: false, method: .socket),
            PathMTUMeasurement(date: ago(60 * 26), target: "1.1.1.1", address: "1.1.1.1", mtu: 1500, maxTested: 1500,
                               kind: .standard, probes: 2, blackHole: false, method: .socket),
            PathMTUMeasurement(date: ago(60 * 30), target: "vpn.exemple.ca", address: "142.112.48.20", mtu: 1500, maxTested: 1500,
                               kind: .standard, probes: 2, blackHole: false, method: .socket),
            PathMTUMeasurement(date: ago(60 * 24 * 6), target: "10.30.0.1", address: "10.30.0.1", mtu: nil, maxTested: 1500,
                               kind: nil, probes: 2, blackHole: false, method: .pingCommand,
                               note: "La cible ne répond pas au ping (ICMP filtré ou appareil éteint)\u{00A0}: le MTU ne peut pas être mesuré."),
        ]
    }
}
