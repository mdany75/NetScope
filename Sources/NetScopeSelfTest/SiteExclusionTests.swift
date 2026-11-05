import Foundation
import NetScopeCore

// Note 82 : plages exclues d'un site. Calcul des adresses à sonder (plages moins exclusions,
// chevauchements, adresses de réseau et de diffusion), moteur de scan qui ne sonde jamais une
// adresse exclue, validation, lecture et écriture (sites.json, CSV), inventaire et relecture
// automatique. Données fixes, aucun réseau.

/// Pinger qui note chaque adresse sondée (et répond pour certaines).
private final class ExclusionRecordingPinger: ScanPinging, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [IPv4Address] = []
    let replies: Set<IPv4Address>

    init(replies: Set<IPv4Address>) { self.replies = replies }

    func ping(_ ip: IPv4Address, timeout: Duration) async -> Double? {
        lock.withLock { seen.append(ip) }
        return replies.contains(ip) ? 1.0 : nil
    }

    var pinged: [IPv4Address] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// Sondes de ports et de noms qui notent les adresses touchées.
private final class ExclusionRecordingProbes: ScanPortProbing, ScanNameResolving, ScanPresenceProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var touched: [IPv4Address] = []

    private func note(_ ip: IPv4Address) {
        lock.lock()
        touched.append(ip)
        lock.unlock()
    }

    func openPorts(_ ip: IPv4Address, ports: [UInt16], timeout: Duration, concurrency: Int) async -> [UInt16] {
        note(ip)
        return []
    }

    func name(for ip: IPv4Address, timeout: Duration) async -> String? {
        note(ip)
        return nil
    }

    func probe(_ ip: IPv4Address, tcpPorts: [UInt16], udpPorts: [UInt16], timeout: Duration) async -> ScanPresenceHit? {
        note(ip)
        return nil
    }

    var addresses: Set<IPv4Address> {
        lock.lock()
        defer { lock.unlock() }
        return Set(touched)
    }
}

/// Valeur présente, sinon échec du test.
private func exclusionRequire<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}

func registerSiteExclusionTests(_ suite: TestSuite) {
    func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }
    func range(_ text: String) -> IPRange { try! IPRange(parsing: text) }
    func exclusions(_ texts: String...) -> AddressExclusions { AddressExclusions(texts.map { ExcludedRange(text: $0) }) }

    suite.add("Plages exclues : adresse, intervalle et sous-réseau ; réseau et diffusion compris") {
        let set = exclusions("10.93.226.254", "10.93.226.1-50", "10.255.1.0/24")
        try expectEqual(set.addressCount, 1 + 50 + 256, "taille sans doublon")
        try expect(set.contains(ip("10.93.226.254")) && set.contains(ip("10.93.226.1")) && set.contains(ip("10.93.226.50")), "bornes comprises")
        try expect(!set.contains(ip("10.93.226.51")) && !set.contains(ip("10.93.226.0")), "hors exclusions")
        // Un sous-réseau exclu couvre son adresse de réseau et sa diffusion.
        try expect(set.contains(ip("10.255.1.0")) && set.contains(ip("10.255.1.255")), "réseau et diffusion du /24 exclus")
        // Dans un /23 scanné, 10.0.0.255 et 10.0.1.0 sont des hôtes : exclure 10.0.1.0/24 les retire.
        let wide = range("10.0.0.0/23")
        let half = exclusions("10.0.1.0/24")
        try expectEqual(wide.count, 510, "hôtes du /23")
        try expectEqual(half.excludedCount(in: [wide]), 255, "10.0.1.0 à 10.0.1.254 (10.0.1.255 est la diffusion du /23)")
        try expectEqual(half.addresses(in: wide).count, 255, "reste 10.0.0.1 à 10.0.0.255")
        try expect(half.addresses(in: wide).contains(ip("10.0.0.255")), "10.0.0.255 reste sondée")
        try expect(!half.addresses(in: wide).contains(ip("10.0.1.0")), "10.0.1.0 exclue")
        // Grande exclusion permise (aucune limite de 65 536 adresses).
        try expectEqual(exclusions("10.0.0.0/8").addressCount, 16_777_216, "un /8 entier")
        // Liste dans une seule saisie.
        try expectEqual(ExcludedRange(text: "10.0.0.9, 10.0.0.12").kindLabel, "Liste", "liste")
        try expectEqual(ExcludedRange(text: "10.0.0.9").kindLabel, "Adresse", "adresse seule")
        try expectEqual(ExcludedRange(text: "10.0.0.1-50").kindLabel, "Intervalle", "intervalle court")
        try expectEqual(ExcludedRange(text: "10.0.0.0/24").kindLabel, "Sous-réseau", "sous-réseau")
        try expect(!ExcludedRange(text: "10.0.0.300").isValid, "adresse illisible")
    }

    suite.add("Plages exclues : chevauchements comptés une fois, plages qui se recouvrent") {
        let set = exclusions("10.0.0.10-30", "10.0.0.20-40", "10.0.0.41", "10.0.0.25")
        try expectEqual(set.intervals.count, 1, "intervalles fusionnés (contigus compris)")
        try expectEqual(set.addressCount, 32, "10.0.0.10 à 10.0.0.41")
        // Deux plages scannées qui se recouvrent : chaque adresse comptée une fois.
        let ranges = [range("10.0.0.0/24"), range("10.0.0.1-50")]
        try expectEqual(set.excludedCount(in: ranges), 32, "exclues")
        try expectEqual(set.probeCount(in: ranges), 254 - 32, "à sonder")
        let parts = set.breakdown(in: ranges)
        try expectEqual(parts.map(\.count), [21, 21, 1, 1], "détail par exclusion saisie")
        try expectEqual(set.reason(for: ip("10.0.0.25"))?.text, "10.0.0.10-30", "première exclusion qui la couvre")
        try expect(set.reason(for: ip("10.0.0.9")) == nil, "aucune raison hors exclusions")
        try expectEqual(AddressExclusions.none.probeCount(in: ranges), 254, "sans exclusion")
        // Exclusion qui déborde de la plage : seule la partie commune compte.
        try expectEqual(exclusions("10.0.0.250-10.0.1.10").excludedCount(in: [range("10.0.0.0/24")]), 5, "10.0.0.250 à .254")
    }

    suite.add("Plages exclues : le moteur de scan ne sonde jamais une adresse exclue") {
        let pinger = ExclusionRecordingPinger(replies: [ip("10.0.0.5"), ip("10.0.0.21"), ip("10.0.0.40")])
        let probes = ExclusionRecordingProbes()
        // L'adresse exclue 10.0.0.22 est dans la table ARP : elle n'est pas ajoutée pour autant.
        let arp = ScanFakeARP(table: [ip("10.0.0.22"): MACAddress("04:d5:90:3a:7b:22")!, ip("10.0.0.40"): MACAddress("04:d5:90:3a:7b:40")!])
        let engine = ScanEngine(pinger: pinger, arp: arp, ports: probes, names: probes, presence: probes)
        var options = ScanOptions(profile: .portsCourants, concurrency: 4)
        options.exclusions = exclusions("10.0.0.20-29", "10.0.0.33")
        let target = ScanTarget(label: "Bureau", range: try IPRange(parsing: "10.0.0.1-40"))
        var started: [Int] = []
        var found = Set<IPv4Address>()
        var summary: ScanSummary?
        for await event in engine.scan([target], options: options) {
            switch event {
            case .started(let ranges): started = ranges.map(\.total)
            case .deviceFound(let device, _), .deviceUpdated(let device, _): found.insert(device.ip)
            case .finished(let result): summary = result
            default: break
            }
        }
        let pinged = Set(pinger.pinged)
        try expectEqual(started, [29], "40 adresses moins 11 exclues")
        try expectEqual(summary?.scannedAddresses, 29, "adresses sondées")
        try expect(!pinged.contains(ip("10.0.0.21")) && !pinged.contains(ip("10.0.0.33")), "aucun ping vers une adresse exclue")
        try expectEqual(pinged.count, 29, "chaque adresse non exclue pingée une fois")
        try expectEqual(found, [ip("10.0.0.5"), ip("10.0.0.40")], "seules les adresses sondées sont trouvées (pas l'exclue de la table ARP)")
        try expect(probes.addresses.isSubset(of: [ip("10.0.0.5"), ip("10.0.0.40")]), "ni ports ni noms vers une adresse exclue")
    }

    suite.add("Plages exclues : validation (plage entière, hors des plages, redondance, illisible)") {
        let bureau = ScanRangeConfig(text: "10.0.0.0/24", label: "Bureau")
        let serveurs = ScanRangeConfig(text: "10.10.0.1-50", label: "Serveurs")
        let whole = ExcludedRange(text: "10.10.0.0/24", note: "serveurs")
        let outside = ExcludedRange(text: "172.16.0.0/16", note: "FortiLink")
        let first = ExcludedRange(text: "10.0.0.100-200")
        let inside = ExcludedRange(text: "10.0.0.150")
        let bad = ExcludedRange(text: "10.0.0.1-0")
        let issues = SiteExclusionCheck.issues([whole, outside, first, inside, bad], ranges: [bureau, serveurs])
        try expectEqual(issues.filter { $0.entryID == whole.id }.map(\.kind), [.coversRange], "couvre toute la plage Serveurs")
        try expect(issues.first { $0.kind == .coversRange }?.message.contains("Serveurs") == true, "nomme la plage")
        try expectEqual(issues.filter { $0.entryID == outside.id }.map(\.kind), [.outsideRanges], "sans effet")
        try expectEqual(issues.filter { $0.entryID == inside.id }.map(\.kind), [.redundant], "déjà couverte")
        try expect(issues.filter { $0.entryID == first.id }.isEmpty, "la première reste sans remarque")
        try expectEqual(issues.filter { $0.entryID == bad.id }.map(\.kind), [.invalid], "illisible")
        try expect(issues.first { $0.kind == .coversRange }?.isWarning == true && issues.first { $0.kind == .outsideRanges }?.isWarning == false,
                   "plage entière : alerte ; hors plages : information")
        // Les illisibles sont ignorées par le scan, sans empêcher les autres.
        try expectEqual(AddressExclusions([bad, inside]).addressCount, 1, "exclusion lisible gardée")
    }

    suite.add("Plages exclues : sites.json, duplication et CSV (export puis import)") {
        let entry = ExcludedRange(text: "10.93.226.1-50", note: "automates")
        var site = Site(name: "Usine", ranges: [ScanRangeConfig(text: "10.93.226.0/24", label: "Production")],
                        created: Date(timeIntervalSince1970: 0), exclusions: [entry, ExcludedRange(text: "10.255.1.0/24", note: "FortiLink")])
        let list = SiteList(sites: [site, Site(name: "Bureau", created: Date(timeIntervalSince1970: 0))], activeID: site.id)
        let data = try exclusionRequire(list.encoded(), "écriture")
        let text = String(decoding: data, as: UTF8.self)
        try expect(text.contains("\"exclusions\""), "exclusions écrites")
        let read = try exclusionRequire(SiteList.decode(data), "relecture")
        try expectEqual(read.sites[0].exclusions, site.exclusions, "exclusions relues à l'identique")
        try expect(read.sites[1].exclusions.isEmpty, "site sans exclusion")
        // Un site sans exclusion n'écrit pas la clé (sites.json identique à avant la 0.27.0).
        let plain = String(decoding: try exclusionRequire(SiteList(sites: [Site(name: "Seul", created: Date(timeIntervalSince1970: 0))]).encoded(), "écriture"), as: UTF8.self)
        try expect(!plain.contains("exclusions"), "aucune clé exclusions inutile")
        // Lecture tolérante : une exclusion sans texte est ignorée sans perdre les autres.
        let json = #"{"version":1,"sites":[{"id":"5A7E0082-0000-4C1E-9A11-000000000001","name":"X","exclusions":[{"note":"vide"},{"text":"10.0.0.5"}]}]}"#
        try expectEqual(SiteList.decode(Data(json.utf8))?.sites.first?.exclusions.map(\.text), ["10.0.0.5"], "exclusion illisible ignorée")
        // Dupliquer le site copie ses exclusions.
        var copyList = list
        let copy = try exclusionRequire(copyList.duplicate(site.id), "copie")
        try expectEqual(copy.exclusions.map(\.label), ["10.93.226.1-50 (automates)", "10.255.1.0/24 (FortiLink)"], "exclusions copiées")
        // CSV : colonne « exclusions » seulement si un site en a ; import d'un site existant.
        let csv = SiteCSV.export(list.sites, controllers: [])
        try expect(csv.hasPrefix(SiteCSV.headerWithExclusions + "\n"), "en-tête à quatre colonnes")
        try expect(csv.contains("10.93.226.1-50 (automates) | 10.255.1.0/24 (FortiLink)"), "exclusions et notes")
        try expect(SiteCSV.export([list.sites[1]], controllers: []).hasPrefix(SiteCSV.header + "\n"), "sans exclusion : trois colonnes")
        let parsed = SiteCSV.parse(csv)
        try expect(parsed.errors.isEmpty, "CSV relu sans erreur")
        try expectEqual(parsed.rows.first?.exclusions?.map(\.label), ["10.93.226.1-50 (automates)", "10.255.1.0/24 (FortiLink)"], "relu")
        try expectEqual(parsed.rows.last?.exclusions?.count, 0, "colonne présente mais vide")
        site.exclusions = []
        let merged = SiteCSV.merge(parsed.rows, into: SiteList(sites: [site]), controllers: [])
        try expectEqual(merged.list.sites[0].exclusions.count, 2, "import : exclusions appliquées au site existant")
        // Sans la colonne, les exclusions d'un site existant restent.
        let old = SiteCSV.parse("site;plages;fortigate\nUsine;10.93.226.0/24 (Production);\n")
        try expect(old.rows.first?.exclusions == nil, "colonne absente")
        let kept = SiteCSV.merge(old.rows, into: SiteList(sites: [Site(name: "Usine", created: Date(), exclusions: [entry])]), controllers: [])
        try expectEqual(kept.list.sites[0].exclusions, [entry], "exclusions gardées")
        let wrong = SiteCSV.parse("site;plages;fortigate;exclusions\nUsine;10.93.226.0/24;;10.0.0.999 (x)\n")
        try expectEqual(wrong.errors.count, 1, "exclusion illisible signalée")
    }

    suite.add("Plages exclues : inventaire (jamais disparu) et relecture automatique") {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let now = old.addingTimeInterval(90 * 86_400)
        let record = InvRecord(key: "ip:10.0.0.5", mac: nil, ip: ip("10.0.0.5"), isOnline: false, firstSeen: old, lastSeen: old)
        try expectEqual(record.status(now: now), .disparu, "sans exclusion : disparu après 30 jours")
        try expectEqual(record.status(now: now, excluded: true), .horsLigne, "exclu : dernier état connu, jamais disparu")
        try expect(!record.isGone(now: now, excluded: true) && record.isGone(now: now, excluded: false), "filtre Disparus")
        // Un switch SNMP dans une plage exclue du site actif n'est jamais relu.
        let site = Site(name: "Siège", ranges: [ScanRangeConfig(text: "10.0.0.0/24", label: "Bureau")],
                        switchHosts: ["10.0.0.2", "10.0.0.3"], exclusions: [ExcludedRange(text: "10.0.0.3", note: "switch fragile")])
        let hosts = AutoRefreshTargets.snmpHosts(["10.0.0.2", "10.0.0.3"], controllerHosts: [], activeSite: site, sites: [site],
                                                 readingSites: [:], scanRanges: [])
        try expectEqual(hosts, ["10.0.0.2"], "switch exclu jamais interrogé")
    }
}
