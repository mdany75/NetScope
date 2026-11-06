import AppKit
import Foundation
import NetScopeCore
import PDFKit

/// Démonstration du bilan de raccordement (note 58) : la prise B du bureau 214 du Siège (switch
/// SW-ETG2-01, port 1/22, comme la Capture LLDP/CDP de démonstration), avant et après
/// l'intervention. Avant : lien à 100 Mb/s en semi-duplex, routeur domestique branché à l'envers
/// (serveur DHCP non autorisé, comme le Test DHCP de démonstration) et pertes vers la passerelle.
/// Après : câble refait, routeur retiré. Aucun accès réseau.
enum LinkCheckDemo {
    static let location = "Bureau 214 · prise B"

    // MARK: Mesures

    static func link(after: Bool) -> LinkCheckLink {
        LinkCheckLink(name: "en7", isWireless: false, kindLabel: "Ethernet", isActive: true, address: IPv4Address("10.182.122.142"),
                      netmask: IPv4Address("255.255.255.0"), gateway: IPv4Address("10.182.122.1"),
                      dnsServers: [IPv4Address("10.182.122.1")!], speedMbps: after ? 1000 : 100,
                      duplex: after ? .full : .half, mediaLabel: after ? "1000baseT" : "100baseTX")
    }

    static func neighbor(at date: Date, listened: Double) -> LinkCheckNeighborMeasure {
        LinkCheckNeighborMeasure(neighbor: CaptureDemo.neighbor(receivedAt: date), listenedSeconds: listened)
    }

    static func dhcp(after: Bool) -> LinkCheckDHCPMeasure {
        var offers = CaptureDemo.offers()
        offers[0].delay = after ? 0.012 : 0.018
        return LinkCheckDHCPMeasure(offers: after ? [offers[0]] : offers, waitedSeconds: 4, method: "démonstration")
    }

    static func gateway(after: Bool) -> LinkCheckGatewayMeasure {
        LinkCheckGatewayMeasure(address: IPv4Address("10.182.122.1")!,
                                rtts: after ? [0.6, 0.8, 0.7, 0.9, 0.6, 0.7, 1.1, 0.7, 0.8, 0.6]
                                            : [2.1, nil, 3.4, 1.9, nil, 2.6, 4.8, 2.2, 3.1, 2.4])
    }

    static func dns(after: Bool) -> LinkCheckDNSMeasure {
        let scale = after ? 1.0 : 3.1
        return LinkCheckDNSMeasure(server: IPv4Address("10.182.122.1"), answers: [
            LinkCheckDNSAnswer(name: "microsoft.com", milliseconds: 18 * scale, addresses: ["20.70.246.20"]),
            LinkCheckDNSAnswer(name: "google.com", milliseconds: 12 * scale, addresses: ["142.250.65.78"]),
            LinkCheckDNSAnswer(name: "cloudflare.com", milliseconds: 9 * scale, addresses: ["104.16.132.229"]),
        ])
    }

    static func internet(after: Bool) -> LinkCheckInternetMeasure {
        LinkCheckInternetMeasure(url: LinkCheckOptions.defaultInternetURL, statusCode: 200, milliseconds: after ? 84 : 212,
                                 expectedTextFound: true)
    }

    /// Bilan composé directement par le moteur de verdicts (mêmes textes qu'un vrai bilan).
    @MainActor
    static func result(after: Bool, date: Date, id: UUID) -> LinkCheckResult {
        let link = link(after: after)
        let neighbor = neighbor(at: date, listened: after ? 9 : 21)
        let allowed = [IPv4Address("10.182.122.1")!]
        let steps = [
            LinkCheckEvaluator.link(link, requested: "en7"),
            LinkCheckEvaluator.switchPort(neighbor, link: link),
            LinkCheckEvaluator.vlan(neighbor, link: link, expected: 1),
            LinkCheckEvaluator.poe(neighbor, link: link),
            LinkCheckEvaluator.dhcp(dhcp(after: after), link: link, allowed: allowed),
            LinkCheckEvaluator.gateway(gateway(after: after), link: link),
            LinkCheckEvaluator.dns(dns(after: after), link: link),
            LinkCheckEvaluator.internet(internet(after: after), link: link),
        ]
        // Note 89 : test de câble du port fait avant le bilan « après » (paires correctes).
        let cable = after ? CableTestResult(date: date.addingTimeInterval(-900), switchName: "SW-ETG2-01", switchHost: "10.182.122.3",
                                            portName: "1/22", vendor: .aruba, channel: "SSH (HPE Aruba)",
                                            pairs: [1, 2, 3, 4].map { CablePairResult(pair: $0, status: .ok, meters: 38) }) : nil
        return LinkCheckResult(id: id, date: date, siteKey: SitesDemo.siegeKey, siteName: "Siège", location: location,
                               interfaceName: "en7", interfaceKind: "Ethernet", steps: steps, duration: after ? 14.2 : 27.8,
                               cableTest: cable)
    }

    /// Bilan d'une autre prise, quelques jours plus tôt (historique).
    @MainActor
    static func olderResult(now: Date) -> LinkCheckResult {
        var link = link(after: true)
        link.address = IPv4Address("10.182.122.163")
        var lldp = CaptureDemo.neighbor(receivedAt: now)
        lldp.portID = "1/7"
        lldp.portDescription = "Salle de conférence - prise 3"
        let neighbor = LinkCheckNeighborMeasure(neighbor: lldp, listenedSeconds: 17)
        let internet = LinkCheckInternetMeasure(url: LinkCheckOptions.defaultInternetURL, statusCode: 200, milliseconds: 1460,
                                                expectedTextFound: true)
        let steps = [
            LinkCheckEvaluator.link(link, requested: "en7"),
            LinkCheckEvaluator.switchPort(neighbor, link: link),
            LinkCheckEvaluator.vlan(neighbor, link: link, expected: nil),
            LinkCheckEvaluator.poe(neighbor, link: link),
            LinkCheckEvaluator.dhcp(dhcp(after: true), link: link, allowed: []),
            LinkCheckEvaluator.gateway(gateway(after: true), link: link),
            LinkCheckEvaluator.dns(dns(after: true), link: link),
            LinkCheckEvaluator.internet(internet, link: link),
        ]
        return LinkCheckResult(id: UUID(uuidString: "B1A7C0DE-0058-4000-8000-000000000003")!, date: now.addingTimeInterval(-3 * 86_400 - 5_400),
                               siteKey: SitesDemo.siegeKey, siteName: "Siège", location: "Salle de conférence · prise 3",
                               interfaceName: "en7", interfaceKind: "Ethernet", steps: steps, duration: 22.4)
    }

    static let beforeID = UUID(uuidString: "B1A7C0DE-0058-4000-8000-000000000001")!
    static let afterID = UUID(uuidString: "B1A7C0DE-0058-4000-8000-000000000002")!

    /// Historique du Siège : bilan d'une autre prise, bilan « avant » (référence) et bilan « après ».
    @MainActor
    static func histories(now: Date = Date()) -> [String: LinkCheckHistory] {
        let before = result(after: false, date: now.addingTimeInterval(-62 * 60), id: beforeID)
        let after = result(after: true, date: now.addingTimeInterval(-6 * 60), id: afterID)
        let history = LinkCheckHistory(results: [after, before, olderResult(now: now)], referenceID: beforeID)
        return [SitesDemo.siegeKey: history]
    }

    /// Entrée du rapport de démonstration (section cochée par NETSCOPE_RAPPORT_RACCORDEMENT=1).
    @MainActor
    static func reportEntries(now: Date = Date()) -> [LinkCheckReportEntry] {
        let h = histories(now: now)[SitesDemo.siegeKey] ?? LinkCheckHistory()
        guard let after = h.result(afterID) else { return [] }
        return [LinkCheckReportEntry(result: after, before: h.reference)]
    }

    /// Sondes simulées du bouton « Lancer le bilan » en démonstration : les mesures « après », avec
    /// de petites attentes pour voir les étapes avancer.
    static func probes() -> any LinkCheckProbing { DemoProbes() }

    private struct DemoProbes: LinkCheckProbing {
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        func link(_ name: String) async -> LinkCheckLink? {
            await pause(0.4)
            return LinkCheckDemo.link(after: true)
        }
        func neighbor(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckNeighborMeasure {
            await pause(6)
            return LinkCheckDemo.neighbor(at: Date(), listened: 6)
        }
        func dhcp(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckDHCPMeasure {
            await pause(1.5)
            return LinkCheckDemo.dhcp(after: true)
        }
        func gateway(_ address: IPv4Address, count: Int, interval: TimeInterval) async -> LinkCheckGatewayMeasure {
            await pause(2)
            return LinkCheckDemo.gateway(after: true)
        }
        func dns(_ names: [String], server: IPv4Address?) async -> LinkCheckDNSMeasure {
            await pause(0.6)
            return LinkCheckDemo.dns(after: true)
        }
        func internet(_ url: URL, expectedText: String?) async -> LinkCheckInternetMeasure {
            await pause(0.4)
            return LinkCheckDemo.internet(after: true)
        }
    }
}

/// Outil de développement : écrit le PDF du bilan de démonstration à côté des captures
/// (`--snapshot <dossier> --demo`) et le relit avec PDFKit.
@MainActor
enum LinkCheckPDFCheck {
    static func write(into directory: URL) -> Bool {
        let model = LinkCheckModel.shared
        guard let result = model.history(forKey: SitesDemo.siegeKey).result(LinkCheckDemo.afterID),
              let data = model.pdfData(result) else {
            print("Erreur\u{00A0}: rendu PDF du bilan de raccordement impossible")
            return false
        }
        let url = directory.appendingPathComponent("bilan-raccordement-demo.pdf")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("Erreur\u{00A0}: \(url.path)\u{00A0}: \(error.localizedDescription)")
            return false
        }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0,
              let text = (0..<pdf.pageCount).compactMap({ pdf.page(at: $0)?.string }).joined(separator: "\n") as String?,
              text.contains("Bilan de raccordement"), text.contains("SW-ETG2-01") else {
            print("Erreur\u{00A0}: PDF du bilan de raccordement illisible ou incomplet")
            return false
        }
        print("Bilan de raccordement PDF\u{00A0}: \(url.path) (\(pdf.pageCount) page\(pdf.pageCount > 1 ? "s" : ""), vérifié)")
        return true
    }
}
