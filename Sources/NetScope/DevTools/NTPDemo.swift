import Foundation
import NetScopeCore

/// Test NTP en démonstration (note 115) : résultats fixes, aucun paquet envoyé.
/// Captures : NETSCOPE_OUTIL_DEMO=ntp ouvre l'outil.
enum NTPDemo {
    static let servers = "10.182.122.1, ntp.exemple.ca, ntp2.exemple.ca, gps.exemple.ca, vieux-nas.exemple.ca, public.exemple.net, panne.exemple.ca"

    static func results(now: Date = Date()) -> [NTPServerResult] {
        func sample(_ server: String, _ address: IPv4Address, leap: Int = 0, stratum: Int, reference: String, kiss: String? = nil,
                    offset: Double, roundTrip: Double) -> NTPServerResult {
            NTPServerResult(server: server, address: address,
                            sample: NTPSample(server: server, address: address, leap: leap, stratum: stratum, poll: 6, precision: -23,
                                              rootDelay: 0.0184, rootDispersion: 0.0312, referenceID: reference, kissCode: kiss,
                                              serverTime: now.addingTimeInterval(offset), offset: offset, roundTrip: roundTrip),
                            sent: kiss == nil ? 4 : 1, answered: kiss == nil ? 4 : 1)
        }
        return [
            sample("10.182.122.1", IPv4Address(10, 182, 122, 1), stratum: 3, reference: "10.182.10.5", offset: 0.0042, roundTrip: 0.0009),
            sample("ntp.exemple.ca", IPv4Address(10, 182, 10, 5), stratum: 2, reference: "10.182.10.2", offset: -0.0187, roundTrip: 0.0064),
            sample("ntp2.exemple.ca", IPv4Address(10, 182, 10, 6), stratum: 2, reference: "10.182.10.2", offset: 0.3421, roundTrip: 0.0071),
            sample("gps.exemple.ca", IPv4Address(10, 182, 10, 2), stratum: 1, reference: "GPS", offset: 0.0011, roundTrip: 0.0052),
            sample("vieux-nas.exemple.ca", IPv4Address(10, 182, 122, 40), leap: 3, stratum: 16, reference: "10.0.0.0", offset: 8040, roundTrip: 0.0021),
            sample("public.exemple.net", IPv4Address(192, 0, 2, 123), leap: 3, stratum: 0, reference: "RATE", kiss: "RATE", offset: 0, roundTrip: 0.0183),
            NTPServerResult(server: "panne.exemple.ca", address: IPv4Address(10, 182, 10, 9), sent: 4),
        ]
    }
}
