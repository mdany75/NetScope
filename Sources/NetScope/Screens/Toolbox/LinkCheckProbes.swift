import Foundation
import NetScopeCore

/// Sondes réelles du bilan de raccordement (note 58) : elles branchent les moteurs existants, sans
/// les recopier. Lien : getifaddrs et SIOCGIFMEDIA (lecture locale) ; switch, VLAN et PoE : capture
/// BPF et décodeur LLDP/CDP de la Capture LLDP/CDP, sinon le dernier voisin qu'elle a gardé ; DHCP :
/// le DHCPDISCOVER du Test DHCP (aucun bail n'est pris) ; passerelle : ping ICMP du Scanner ; DNS :
/// moteur de l'outil DNS ; Internet : sonde HTTP de la Surveillance.
///
/// Jamais utilisées en démonstration ni pendant les captures (LinkCheckDemo.probes).
struct LiveLinkCheckProbes: LinkCheckProbing {
    /// Dernier voisin de la Capture LLDP/CDP et le réseau où il a été entendu.
    let previousNeighbor: NetworkNeighbor?
    let previousContext: NetworkContext?
    let pinger: ICMPPinger?

    // MARK: Lien

    func link(_ name: String) async -> LinkCheckLink? {
        let list = await LocalInterfaces.linkInterfacesWithKinds()
        guard let local = list.first(where: { $0.name == name }) else { return nil }
        let media = LinkMedia.read(name)
        let baudRate = LocalResources.interfaces().first { $0.name == name }?.counters.speedMbps
        let gateway: IPv4Address? = local.gateway ?? {
            // Route par défaut, seulement si elle est dans le réseau de cette interface.
            guard local.hasIPv4, let gateway = ScanNetwork.defaultGateway(), local.subnet.contains(gateway) else { return nil }
            return gateway
        }()
        return LinkCheckLink(name: name, isWireless: local.kind == .wifi, kindLabel: local.kind == .wifi ? "Wi-Fi" : (local.kind == .ethernet ? "Ethernet" : local.kind.label),
                             isActive: media?.isActive, address: local.hasIPv4 ? local.address : nil,
                             netmask: local.hasIPv4 ? local.netmask : nil, gateway: gateway,
                             dnsServers: ScanNetwork.dnsServers(), speedMbps: media?.speedMbps ?? baudRate,
                             duplex: media?.duplex, mediaLabel: media?.label)
    }

    // MARK: Switch, VLAN et PoE

    func neighbor(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckNeighborMeasure {
        let start = Date()
        guard await Task.detached(operation: { BPFCapture.readableDevice() != nil }).value,
              let capture = try? BPFCapture(interface: link.name, filter: BPFFilter.neighbors, promiscuous: true) else {
            return previousOrNothing(link, reason: "L’accès direct aux trames (/dev/bpf) n’est pas permis sur ce Mac\u{00A0}: lancez une fois la Capture LLDP/CDP (avec l’autorisation d’administrateur) sur cette prise, puis relancez le bilan.")
        }
        defer { capture.stop() }
        var frames: [CapturedFrame] = []
        let end = start.addingTimeInterval(seconds)
        while !Task.isCancelled, Date() < end {
            let batch = await Task.detached { capture.read(timeout: 0.5) }.value
            guard !batch.isEmpty else { continue }
            frames += batch
            // Première annonce reçue : inutile d'attendre la fin (LLDP toutes les 30 s, CDP toutes les 60 s).
            let decoded = NeighborFrameDecoder.neighbors(in: frames, interface: link.name)
            if let first = decoded.first(where: { $0.protocols.contains(.lldp) }) ?? decoded.first {
                return LinkCheckNeighborMeasure(neighbor: first, listenedSeconds: Date().timeIntervalSince(start))
            }
        }
        return LinkCheckNeighborMeasure(neighbor: nil, listenedSeconds: Date().timeIntervalSince(start))
    }

    /// Voisin de la dernière capture, s'il a été entendu sur ce même lien (même interface, même
    /// réseau, câble jamais débranché depuis).
    private func previousOrNothing(_ link: LinkCheckLink, reason: String) -> LinkCheckNeighborMeasure {
        if let neighbor = previousNeighbor, let context = previousContext, context.interface == link.name {
            var current = NetworkContext(interface: link.name, gateway: link.gateway, linkStamp: LocalInterfaces.linkStamps()[link.name])
            if let address = link.address, let netmask = link.netmask {
                current.subnet = LocalInterface(name: link.name, address: address, netmask: netmask).subnet
            }
            if !context.isStale(comparedTo: current) {
                return LinkCheckNeighborMeasure(neighbor: neighbor, fromPreviousCapture: true, unavailableReason: reason)
            }
        }
        return LinkCheckNeighborMeasure(neighbor: nil, unavailableReason: reason)
    }

    // MARK: DHCP

    func dhcp(on link: LinkCheckLink, seconds: TimeInterval) async -> LinkCheckDHCPMeasure {
        guard let mac = LinkLayer.macAddress(of: link.name) else {
            return LinkCheckDHCPMeasure(offers: [], waitedSeconds: 0, unavailableReason: "Adresse MAC de \(link.name) introuvable.")
        }
        let xid = DHCPDiscover.randomXID()
        let packet = DHCPDiscover.build(xid: xid, mac: mac)
        switch await ToolDHCPModel.discoverWithoutPrivilege(interface: link.name, packet: packet, xid: xid, seconds: seconds) {
        case .received(let offers, let reception, let error):
            if let error, offers.isEmpty {
                return LinkCheckDHCPMeasure(offers: [], waitedSeconds: seconds, unavailableReason: "Le DHCPDISCOVER n’a pas pu partir\u{00A0}: \(error)")
            }
            return LinkCheckDHCPMeasure(offers: DHCPServerPolicy.uniqueServers(offers, xid: xid), waitedSeconds: seconds,
                                        method: reception.label,
                                        emptyHint: reception == .sharedPort
                                            ? "macOS a peut-être gardé les réponses pour lui\u{00A0}: le Test DHCP, avec l’autorisation d’administrateur, les montrera." : nil)
        case .needsPrivilege:
            return LinkCheckDHCPMeasure(offers: [], waitedSeconds: 0,
                                        unavailableReason: "macOS garde le port UDP\u{00A0}68 et l’accès direct aux trames n’est pas permis\u{00A0}: lancez le Test DHCP (avec l’autorisation d’administrateur) pour lire les offres.")
        }
    }

    // MARK: Passerelle, DNS, Internet

    func gateway(_ address: IPv4Address, count: Int, interval: TimeInterval) async -> LinkCheckGatewayMeasure {
        guard let pinger else {
            return LinkCheckGatewayMeasure(address: address, rtts: [], unavailableReason: "Le ping ICMP n’est pas disponible sur ce Mac.")
        }
        return await LinkCheckPing.measure(address, pinger: pinger, count: count, interval: interval)
    }

    func dns(_ names: [String], server: IPv4Address?) async -> LinkCheckDNSMeasure {
        var answers: [LinkCheckDNSAnswer] = []
        for name in names {
            if Task.isCancelled { break }
            do {
                let result = try await DNSLookup.resolve(name, type: .a, server: server, timeout: 2)
                let addresses = result.records.filter { $0.type == .a }.map(\.value)
                answers.append(LinkCheckDNSAnswer(name: name, milliseconds: result.durationMs, addresses: addresses,
                                                  error: addresses.isEmpty ? "réponse \(result.rcode) sans adresse" : nil))
            } catch {
                answers.append(LinkCheckDNSAnswer(name: name, milliseconds: nil,
                                                  error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return LinkCheckDNSMeasure(server: server, answers: answers)
    }

    func internet(_ url: URL, expectedText: String?) async -> LinkCheckInternetMeasure {
        do {
            let result = try await HTTPProbe.probe(url, timeout: 8)
            let found = expectedText.map { result.bodyText.contains($0) }
            let finalHost = result.finalURL.host != url.host ? result.finalURL.host : nil
            return LinkCheckInternetMeasure(url: url, statusCode: result.statusCode, milliseconds: result.durationMs,
                                            expectedTextFound: found, finalHost: finalHost)
        } catch {
            return LinkCheckInternetMeasure(url: url, error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
