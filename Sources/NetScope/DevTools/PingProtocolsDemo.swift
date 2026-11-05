import Foundation
import NetScopeCore

/// Ping TCP et HTTP et traceroute TCP/UDP en démonstration (note 65) : deux cibles de plus dans
/// le Ping continu (le serveur de fichiers qui bloque l'ICMP, sondé en TCP 3389, et le portail
/// web de l'entreprise en HTTPS), mesures simulées, aucun paquet envoyé.
@MainActor
enum PingProtocolsDemo {
    static let rdpInput = "tcp://10.10.0.12:3389"
    static let webInput = "https://portail.exemple.ca/"

    static let profiles: [PingDemo.Profile] = [
        PingDemo.Profile(input: rdpInput, name: "SRV-FICHIERS", role: "ICMP bloqué", base: 1.6, jitter: 0.9,
                         loss: 0.002, burst: 0, spike: 0.01, threshold: 15),
        PingDemo.Profile(input: webInput, name: "Portail web", role: "Internet", base: 46.5, jitter: 6.5, loss: 0.003,
                         burst: 0, spike: 0.03, threshold: 150),
    ]

    /// Adresse des noms de la démonstration (aucune résolution DNS).
    static func address(for host: String) -> IPv4Address? {
        host == "portail.exemple.ca" ? IPv4Address(142, 112, 48, 20) : nil
    }

    /// Mesure simulée selon le protocole : code 200 et découpage du temps en HTTPS.
    static func sample(sequence: Int, date: Date, rttMs: Double?, kind: PingProbeKind) -> PingSample {
        guard case .http = kind else { return PingSample(sequence: sequence, date: date, rttMs: rttMs) }
        guard let rttMs else { return PingSample(sequence: sequence, date: date, rttMs: nil, failure: .timeout) }
        // DNS en cache, TCP ≈ 22 %, TLS ≈ 30 %, le reste à attendre le serveur.
        let tcp = (rttMs * 0.22 * 10).rounded() / 10, tls = (rttMs * 0.30 * 10).rounded() / 10
        let timing = PingHTTPTiming(tcpMs: tcp, tlsMs: tls, waitMs: max(0, rttMs - tcp - tls), totalMs: rttMs)
        return PingSample(sequence: sequence, date: date, rttMs: rttMs, statusCode: 200, detail: timing.summary)
    }

    /// Historique prérempli, refait avec les codes HTTP.
    static func decorate(_ history: PingHistory, kind: PingProbeKind) -> PingHistory {
        guard case .http = kind else { return history }
        var result = PingHistory()
        for sample in history.samples {
            result.append(Self.sample(sequence: sample.sequence, date: sample.date, rttMs: sample.rttMs, kind: kind))
        }
        return result
    }
}

extension PingDemo {
    /// Sauts simulés selon le protocole du traceroute : en TCP, la destination répond par un
    /// SYN/ACK un peu plus lent qu'un écho ; en UDP, le routeur du fournisseur (100.64.0.1) ne
    /// répond pas aux sondes UDP (filtrage courant), ce qui se voit en perte à ce saut seulement.
    static func hops(to destination: IPv4Address, profile: Profile?, traceProtocol: PingTraceProtocol) -> [Hop] {
        let base = hops(to: destination, profile: profile)
        switch traceProtocol {
        case .icmp:
            return base
        case .tcp:
            return base.enumerated().map { index, hop in
                index == base.count - 1 ? Hop(address: hop.address, base: hop.base + 0.4, jitter: hop.jitter, loss: hop.loss) : hop
            }
        case .udp:
            return base.map { hop in
                hop.address == "100.64.0.1" ? Hop(address: hop.address, base: hop.base, jitter: hop.jitter, loss: 1) : hop
            }
        }
    }

    static func report(to destination: IPv4Address, profile: Profile?, cycles: Int, traceProtocol: PingTraceProtocol) -> PingMTRReport {
        guard traceProtocol != .icmp else { return report(to: destination, profile: profile, cycles: cycles) }
        var report = PingMTRReport(destination: destination)
        let hops = hops(to: destination, profile: profile, traceProtocol: traceProtocol)
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
