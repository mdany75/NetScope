import Foundation
import NetScopeCore

// Note 78 (Historique et adressage) : plan d'adressage de /24 à /16 par pages de /24, croisement
// avec les baux et réservations DHCP de la FortiGate et les plages exclues, prochaine IP libre hors
// étendue DHCP. Données fixes, aucun réseau.

func registerAddressPlanTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }
    func subnet(_ text: String) -> Subnet { try! Subnet(parsing: text) }
    func record(_ address: String, online: Bool = true, daysAgo: Double = 0, conflict: Bool = false) -> InvRecord {
        let seen = now.addingTimeInterval(-daysAgo * 86_400)
        return InvRecord(key: "ip:\(address)", mac: nil, ip: ip(address), isOnline: online, firstSeen: seen, lastSeen: seen,
                         conflictWith: conflict ? [MACAddress("00:11:22:33:44:55")!] : [])
    }
    func range(_ a: String, _ b: String) -> DHCPAddressRange { DHCPAddressRange(start: ip(a), end: ip(b)) }

    // Étendue du Bureau : 10.0.0.100-199 sauf 120-129, passerelle .1, réservations .110 (pool) et .20 (hors pool).
    let report = DHCPScopeReadReport(
        servers: [DHCPServerConfig(id: 1, interface: "internal", ranges: [range("10.0.0.100", "10.0.0.199")],
                                   exclusions: [range("10.0.0.120", "10.0.0.129")],
                                   reservations: [DHCPReservation(ip: ip("10.0.0.110"), action: "reserved"),
                                                  DHCPReservation(ip: ip("10.0.0.20"), action: "reserved"),
                                                  DHCPReservation(ip: ip("10.0.0.21"), action: "block")],
                                   gateway: ip("10.0.0.1"), netmask: ip("255.255.252.0")),
                  DHCPServerConfig(id: 2, interface: "vlan20", ranges: [range("10.0.2.50", "10.0.2.99")],
                                   gateway: ip("10.0.2.1"), netmask: ip("255.255.255.0"))],
        leases: [DHCPLeaseEntry(ip: ip("10.0.0.150"), serverID: 1),
                 DHCPLeaseEntry(ip: ip("10.0.0.151"), expires: now.addingTimeInterval(-60), serverID: 1), // expiré
                 DHCPLeaseEntry(ip: ip("10.0.0.152"), serverID: 1, status: "released"),
                 DHCPLeaseEntry(ip: ip("10.0.2.60"), serverID: 2)],
        interfaces: ["internal": DHCPInterfaceInfo(alias: "Bureau"), "vlan20": DHCPInterfaceInfo(vlan: 20, alias: "Voix")])

    suite.add("Plan d'adressage : états d'une page (/24) croisés avec le DHCP et les exclusions") {
        let dhcp = AddressPlanDHCP(reports: [report], now: now)
        let records = [record("10.0.0.1"), record("10.0.0.2", online: false, daysAgo: 2), record("10.0.0.3", online: false, daysAgo: 40),
                       record("10.0.0.4", conflict: true), record("10.0.0.110")]
        let exclusions = AddressExclusions([ExcludedRange(text: "10.0.0.200-209", note: "automates")])
        let plan = AddressPlan(block: subnet("10.0.0.0/24"), records: records, dhcp: dhcp, exclusions: exclusions, now: now)
        func state(_ text: String) -> AddressPlanState { plan.cell(ip(text)).state }
        try expectEqual(plan.pageCount, 1, "une page")
        try expectEqual(state("10.0.0.0"), .reseau, "réseau")
        try expectEqual(state("10.0.0.255"), .reseau, "diffusion")
        try expectEqual(state("10.0.0.1"), .enLigne, "passerelle en ligne : la fiche l'emporte")
        try expectEqual(state("10.0.0.2"), .horsLigne, "hors ligne récent")
        try expectEqual(state("10.0.0.3"), .libre, "fiche ancienne : adresse libre")
        try expectEqual(state("10.0.0.4"), .conflit, "conflit")
        try expectEqual(state("10.0.0.20"), .reservee, "réservation hors plage : gardée")
        try expectEqual(state("10.0.0.21"), .libre, "réservation « block » : ne garde rien")
        try expectEqual(state("10.0.0.110"), .enLigne, "réservée et vue en ligne")
        try expectEqual(state("10.0.0.150"), .bail, "bail actif sans fiche")
        try expectEqual(state("10.0.0.151"), .libreDHCP, "bail expiré : libre dans l'étendue")
        try expectEqual(state("10.0.0.152"), .libreDHCP, "bail libéré")
        try expectEqual(state("10.0.0.125"), .libre, "exclusion DHCP : hors étendue")
        try expectEqual(state("10.0.0.205"), .exclue, "plage exclue du scan : état inconnu")
        let cell = plan.cell(ip("10.0.0.150"))
        try expect(cell.inPool && cell.scopeName == "internal · Bureau" && cell.lease != nil, "détail du bail")
        try expectEqual(plan.cell(ip("10.0.0.205")).exclusion?.note, "automates", "raison de l'exclusion")
        let page = plan.pages[0]
        try expectEqual(page.hosts, 254, "254 adresses attribuables")
        // Pris : .1, .2, .4, .20, .110, .150 = 6.
        try expectEqual(page.used, 6, "adresses prises")
        try expectEqual(page.count(.libreDHCP), 100 - 10 - 2, "pool moins .110 et .150")
        try expectEqual(page.count(.exclue), 10, "exclues")
        // Prochaine IP libre hors étendue : .3 (fiche ancienne), puis .5…
        try expectEqual(plan.freeAddresses(limit: 3), [ip("10.0.0.3"), ip("10.0.0.5"), ip("10.0.0.6")], "candidates pour une IP fixe")
        try expect(!plan.freeAddresses().contains(ip("10.0.0.150")) && !plan.freeAddresses().contains(ip("10.0.0.205")),
                   "jamais un bail ni une adresse exclue")
        try expect(!plan.freeAddresses().contains { (100...199).contains($0.octets.3) && !(120...129).contains($0.octets.3) },
                   "jamais dans l'étendue DHCP")
    }

    suite.add("Plan d'adressage : bloc /22 en pages de /24, réseau et diffusion des sous-réseaux connus") {
        let dhcp = AddressPlanDHCP(reports: [report], now: now)
        let records = [record("10.0.0.1"), record("10.0.1.0"), record("10.0.2.10"), record("10.0.3.255", online: false, daysAgo: 1)]
        // 10.0.2.0/24 (étendue VLAN 20) est un sous-réseau connu : ses .0 et .255 ne sont pas libres.
        let plan = AddressPlan(block: subnet("10.0.0.0/22"), records: records, dhcp: dhcp, subnets: [subnet("10.0.2.0/24")], now: now)
        try expectEqual(plan.pageCount, 4, "4 pages")
        try expectEqual(plan.pages.map(\.shortLabel), [".0", ".1", ".2", ".3"], "pages")
        try expectEqual(plan.cell(ip("10.0.0.0")).state, .reseau, "réseau du /22")
        try expectEqual(plan.cell(ip("10.0.3.255")).state, .reseau, "diffusion du /22 (même avec une fiche)")
        try expectEqual(plan.cell(ip("10.0.1.0")).state, .enLigne, "10.0.1.0 est un hôte du /22")
        try expectEqual(plan.cell(ip("10.0.0.255")).state, .libre, "10.0.0.255 aussi")
        try expectEqual(plan.cell(ip("10.0.2.0")).state, .reseau, "réseau du /24 de l'étendue")
        try expectEqual(plan.cell(ip("10.0.2.255")).state, .reseau, "diffusion du /24 de l'étendue")
        try expectEqual(plan.cell(ip("10.0.2.60")).state, .bail, "bail de la page .2")
        try expectEqual(plan.pages.map(\.hosts), [255, 256, 254, 255], "adresses attribuables par page")
        try expectEqual(plan.hosts, 1020, "hôtes du /22 moins réseau et diffusion du /24 connu")
        try expectEqual(plan.page(containing: ip("10.0.2.77"))?.base, ip("10.0.2.0"), "page d'une adresse")
        try expectEqual(plan.defaultPage().base, ip("10.0.0.0"), "première page occupée")
        try expectEqual(plan.defaultPage(preferring: ip("10.0.3.9")).base, ip("10.0.3.0"), "page préférée")
        // Prochaine IP libre par sous-réseau, jamais .0 ni .255 même dans le /22.
        try expectEqual(plan.nextFree(in: subnet("10.0.1.0/24")), ip("10.0.1.1"), "page .1")
        try expectEqual(plan.nextFree(in: subnet("10.0.2.0/24")), ip("10.0.2.2"), "page .2 : .1 passerelle, puis .2")
        try expect(!plan.freeAddresses().contains { $0.octets.3 == 0 || $0.octets.3 == 255 }, "jamais .0 ni .255")
        // Bloc ramené entre /16 et /24.
        try expectEqual(AddressPlan(block: subnet("10.0.0.128/25"), records: []).block, subnet("10.0.0.0/24"), "/25 → /24")
        try expectEqual(AddressPlan(block: subnet("10.0.0.0/12"), records: []).pageCount, 256, "/12 → /16")
    }

    suite.add("Plan d'adressage : /16 (256 pages) et sous-réseaux d'un site") {
        let records = (0..<40).map { record("10.182.122.\($0 + 2)") } + [record("10.182.130.5")]
        let plan = AddressPlan(block: subnet("10.182.0.0/16"), records: records, dhcp: AddressPlanDHCP(reports: [], now: now), now: now)
        try expectEqual(plan.pageCount, 256, "256 pages de /24")
        try expectEqual(plan.used, 41, "fiches comptées une fois")
        try expectEqual(plan.page(containing: ip("10.182.122.9"))?.used, 40, "page .122")
        try expectEqual(plan.pages.filter { !$0.isEmpty }.map(\.shortLabel), [".122", ".130"], "pages occupées")
        try expectEqual(plan.nextFree(), ip("10.182.0.1"), "première libre du bloc")
        // Sous-réseaux du site : plages du Scanner, étendues DHCP, /24 des fiches.
        let ranges = [ScanRangeConfig(text: "10.0.0.0/22", label: "Bureau", vlan: 1), ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs", vlan: 100),
                      ScanRangeConfig(text: "10.0.0.0/8", label: "Trop grand")]
        let list = AddressPlanSubnet.list(ranges: ranges, dhcp: [report], records: [record("10.0.0.7"), record("192.168.5.3")])
        try expectEqual(list.map(\.id), ["10.0.0.0/22", "10.0.2.0/24", "10.10.0.0/24", "192.168.5.0/24"], "sous-réseaux, triés, sans le /8")
        let bureau = list[0]
        try expectEqual(bureau.labels, ["Bureau"], "libellé de la plage")
        try expectEqual(bureau.dhcpName, "internal · Bureau", "étendue (masque /22) rattachée")
        try expectEqual(bureau.dhcpRangesLabel, "10.0.0.100 – 119, 10.0.0.130 – 199", "plages distribuables abrégées")
        try expectEqual(list[1].label, "VLAN 20", "étendue VLAN 20")
        try expectEqual(list[2].label, "Serveurs · VLAN 100", "intervalle → son /24")
        try expectEqual(AddressPlanSubnet.enclosingBlock(of: ip("10.0.1.0"), in: list), subnet("10.0.0.0/22"), "bloc proposé")
        try expect(AddressPlanSubnet.enclosingBlock(of: ip("10.10.0.0"), in: list) == nil, "un /24 seul : pas de bloc")
    }
}
