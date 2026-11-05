import Foundation
import NetScopeCore

/// Données simulées du ping continu (mode --demo et captures --snapshot), reprises du croquis
/// docs/croquis/Ping.dc.html. Aucun paquet n'est envoyé.
@MainActor
enum PingDemo {
    /// Profil de latence d'une cible simulée.
    struct Profile {
        let input: String, name: String, role: String
        let base: Double, jitter: Double, loss: Double, burst: Double, spike: Double, threshold: Double
    }

    static let profiles: [Profile] = [
        Profile(input: "10.182.122.1", name: "FortiGate-60F", role: "Passerelle", base: 2.1, jitter: 1.3, loss: 0.002, burst: 0, spike: 0.01, threshold: 15),
        Profile(input: "10.182.122.2", name: "SW-CORE-01", role: "Catalyst 9300-48P", base: 2.6, jitter: 1.6, loss: 0.004, burst: 0, spike: 0.03, threshold: 15),
        Profile(input: "10.182.122.111", name: "Brother DCP-L2640DW", role: "SW-ETG2-01 · 1/14", base: 3.4, jitter: 1.9, loss: 0.006, burst: 0, spike: 0.02, threshold: 20),
        Profile(input: "8.8.8.8", name: "Google DNS", role: "Internet", base: 13.6, jitter: 1.8, loss: 0.004, burst: 0, spike: 0.015, threshold: 40),
        Profile(input: "1.1.1.1", name: "Cloudflare", role: "Internet", base: 11.8, jitter: 1.5, loss: 0.003, burst: 0, spike: 0.015, threshold: 40),
        Profile(input: "192.168.50.21", name: "Caméra-Quai", role: "Caméra · VLAN 40", base: 3.9, jitter: 2.4, loss: 0.025, burst: 0.012, spike: 0.04, threshold: 20),
    ]

    /// Générateur pseudo-aléatoire reproductible (SplitMix64) : les captures sont identiques d'un lancement à l'autre.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func gauss() -> Double {
            let u = max(1e-12, 1 - next()), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    static var random = Random(state: 0x5EED_2026)
    private static var bursts: [String: Int] = [:]

    /// Mesure simulée (nil : perdu).
    static func sample(for profile: Profile, payloadSize: Int = 56) -> Double? {
        if let remaining = bursts[profile.input], remaining > 0 {
            bursts[profile.input] = remaining - 1
            return nil
        }
        if random.next() < profile.burst {
            bursts[profile.input] = 2 + Int(random.next() * 3)
            return nil
        }
        if random.next() < profile.loss { return nil }
        var value = profile.base + abs(random.gauss()) * profile.jitter * 0.7 + (random.next() - 0.5) * profile.jitter * 0.4
        if random.next() < profile.spike { value += profile.base * (1.2 + random.next() * 2.5) }
        if payloadSize > 1000 { value += profile.base > 10 ? 0.6 : 0.35 }
        return max(0.3, (value * 10).rounded() / 10)
    }

    static func profile(for input: String) -> Profile? {
        profiles.first { $0.input == input }
    }

    /// Profil générique pour une cible ajoutée en démonstration.
    static func genericProfile(for input: String, address: IPv4Address?) -> Profile {
        let local = address.map { AddressScope.of($0) == .privee } ?? false
        return Profile(input: input, name: input, role: "Ajoutée", base: local ? 3.2 : 18.5, jitter: local ? 1.8 : 2.6,
                       loss: 0.01, burst: 0, spike: 0.02, threshold: local ? 20 : 50)
    }

    /// 120 mesures déjà enregistrées par cible, avec les incidents du croquis.
    static func prefill(_ profile: Profile, now: Date) -> PingHistory {
        var values = (0..<120).map { _ in sample(for: profile) }
        switch profile.input {
        case "192.168.50.21": for index in 76...79 { values[index] = nil }
        case "10.182.122.2": values[101] = 17.4
        case "10.182.122.111": values[52] = nil
        default: break
        }
        if values[119] == nil { values[119] = profile.base }
        if values[118] == nil { values[118] = profile.base }
        var history = PingHistory()
        for (index, value) in values.enumerated() {
            history.append(PingSample(sequence: index + 1, date: now.addingTimeInterval(Double(index - 119)), rttMs: value))
        }
        return history
    }

    /// Cible mise en pause dans la démonstration (0.21.0) : l'imprimante, depuis la mesure 86
    /// (35 s avant la capture) ; sa carte est atténuée avec la pastille « En pause ».
    static let pausedInput = "10.182.122.111"
    static let pausedIndex = 85

    /// Heure de la mesure `index` des données préremplies (la dernière, 119, est « maintenant »).
    static func date(of index: Int, now: Date) -> Date {
        now.addingTimeInterval(Double(index - 119))
    }

    static func events(now: Date) -> [PingEvent] {
        let at = { (index: Int) in now.addingTimeInterval(Double(index - 119)) }
        return [
            PingEvent(date: at(101), level: .alerte, subject: "10.182.122.2",
                      message: "latence élevée 17,4 ms (seuil 15 ms), CPU du switch qui dépriorise l’ICMP"),
            PingEvent(date: at(pausedIndex), level: .info, subject: pausedInput,
                      message: PingPausePeriods.journalMessage(paused: true)),
            PingEvent(date: at(80), level: .retabli, subject: "192.168.50.21", message: "retour en ligne après 4 s (4 paquets perdus)"),
            PingEvent(date: at(78), level: .coupure, subject: "192.168.50.21", message: "délai dépassé (3 paquets perdus)"),
            PingEvent(date: at(53), level: .alerte, subject: "10.182.122.111", message: "1 paquet perdu (seq 53)"),
            PingEvent(date: at(0).addingTimeInterval(-1), level: .info, subject: "Session",
                      message: "surveillance démarrée · 6 cibles · ICMP · 56 octets · 1 s"),
        ]
    }

    // MARK: MTR simulé

    struct Hop { let address: String; let base: Double; let jitter: Double; let loss: Double }

    static let hostnames: [IPv4Address: String] = [
        IPv4Address("10.182.122.1")!: "FortiGate-60F",
        IPv4Address("8.8.8.8")!: "dns.google",
        IPv4Address("1.1.1.1")!: "one.one.one.one",
    ]

    static func hops(to destination: IPv4Address, profile: Profile?) -> [Hop] {
        let base = profile?.base ?? 15, jitter = profile?.jitter ?? 2
        let final = Hop(address: destination.description, base: base, jitter: jitter, loss: (profile?.loss ?? 0.01) + (profile?.burst ?? 0) * 3)
        let gateway = Hop(address: "10.182.122.1", base: 2.1, jitter: 1.3, loss: 0)
        if Subnet(address: IPv4Address("10.182.122.0")!, prefix: 24).contains(destination) { return [final] }
        if AddressScope.of(destination) == .privee { return [gateway, final] }
        let isp = [Hop(address: "100.64.0.1", base: 5.2, jitter: 1.6, loss: 0),
                   Hop(address: "154.11.12.37", base: 7.4, jitter: 2.2, loss: 0.04),
                   Hop(address: "154.11.6.225", base: 9.6, jitter: 1.4, loss: 0)]
        switch destination.description {
        case "8.8.8.8":
            return [gateway] + isp + [Hop(address: "72.14.211.106", base: 11.9, jitter: 1.3, loss: 0),
                                      Hop(address: "108.170.250.225", base: 12.6, jitter: 1.6, loss: 0),
                                      Hop(address: "142.250.236.211", base: 13.1, jitter: 1.4, loss: 0), final]
        case "1.1.1.1":
            return [gateway] + isp + [Hop(address: "162.158.140.3", base: 11.2, jitter: 1.2, loss: 0), final]
        default:
            return [gateway] + isp + [final]
        }
    }

    /// Un cycle MTR simulé.
    static func cycle(hops: [Hop]) -> PingTraceCycle {
        var replies: [Int: PingHopReply] = [:]
        for (index, hop) in hops.enumerated() where random.next() >= hop.loss {
            let value = max(0.3, ((hop.base + abs(random.gauss()) * hop.jitter * 0.7) * 10).rounded() / 10)
            replies[index + 1] = PingHopReply(address: IPv4Address(hop.address)!, rttMs: value, reachedDestination: index == hops.count - 1)
        }
        return PingTraceCycle(probed: hops.count, replies: replies)
    }

    static func report(to destination: IPv4Address, profile: Profile?, cycles: Int) -> PingMTRReport {
        var report = PingMTRReport(destination: destination)
        let hops = hops(to: destination, profile: profile)
        // Le premier cycle atteint toujours la destination, pour fixer le nombre de sauts.
        var first = cycle(hops: hops)
        if first.destinationTTL == nil {
            var replies = first.replies
            replies[hops.count] = PingHopReply(address: destination, rttMs: profile?.base ?? 15, reachedDestination: true)
            first = PingTraceCycle(probed: hops.count, replies: replies)
        }
        report.record(first)
        for _ in 1..<max(1, cycles) { report.record(cycle(hops: hops)) }
        return report
    }
}
