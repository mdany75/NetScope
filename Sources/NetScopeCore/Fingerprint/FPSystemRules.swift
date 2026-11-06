import Foundation

/// Empreinte d'un appareil : services un par un, puis système d'après tous les indices concordants
/// (services, sysDescr, TXT mDNS, TTL, ports et fabricant). Pur, sans réseau.
public enum Fingerprinter {
    public static func analyze(_ evidence: FPEvidence?, openPorts: [UInt16] = [], vendor: String? = nil) -> FPReport {
        var services: [FPServiceResult] = []
        var votes: [FPVote] = []
        for observation in evidence?.services ?? [] {
            let evaluated = FPServiceRules.evaluate(observation)
            services.append(evaluated.result)
            votes += evaluated.votes
        }
        if let descr = evidence?.sysDescr { votes += FPSystemRules.sysDescr(descr, objectID: evidence?.sysObjectID) }
        if let txt = evidence?.mdnsTXT, !txt.isEmpty { votes += FPSystemRules.mdns(txt) }
        votes += FPSystemRules.ports(openPorts)
        if let vendor { votes += FPSystemRules.vendor(vendor) }
        let system = FPSystemRules.decide(votes, ttl: evidence?.ttl)
        return FPReport(system: system, services: services.sorted { $0.port < $1.port })
    }
}

public enum FPSystemRules {
    // MARK: Décision

    static func score(_ weight: FPConfidence) -> Int {
        switch weight {
        case .faible: return 1
        case .moyenne: return 2
        case .forte: return 4
        }
    }

    /// Famille la mieux appuyée ; le TTL ne fait que confirmer (ou, seul, donner une piste faible).
    static func decide(_ votes: [FPVote], ttl: Int?) -> FPSystemResult? {
        let ttlClass = ttl.flatMap(initialTTL)
        var scores: [FPSystemFamily: Int] = [:]
        for vote in votes { scores[vote.family, default: 0] += score(vote.clue.weight) }
        // Un nom précis de Linux (Ubuntu, Proxmox) l'emporte sur « Linux embarqué » à score égal.
        let ranked = scores.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : order(lhs.key) < order(rhs.key)
        }
        guard let best = ranked.first else {
            return ttlClass.map(ttlOnly)
        }
        let family = best.key
        var chosen = votes.filter { $0.family == family }
        var total = best.value
        if let ttl, let ttlClass, compatible(family, ttl: ttlClass) {
            let clue = FPClue(source: .ttl, observed: "TTL \(ttl)", conclusion: "TTL initial \(ttlClass), cohérent", weight: .faible)
            chosen.append(FPVote(family: family, clue: clue))
            total += 1
        }
        // Indices qui contredisent la famille retenue : la confiance baisse d'un cran.
        let contradicted = ranked.dropFirst().contains { $0.value >= 2 }
        let strongest = chosen.map(\.clue.weight).max() ?? .faible
        var confidence: FPConfidence = strongest == .forte || total >= 5 ? .forte : (total >= 2 ? .moyenne : .faible)
        if contradicted, confidence > .faible, !(strongest == .forte && total >= 6) {
            confidence = FPConfidence(rawValue: confidence.rawValue - 1) ?? .faible
        }
        let byWeight = chosen.sorted { score($0.clue.weight) > score($1.clue.weight) }
        let name = byWeight.first { $0.name != nil && $0.name != family.label }?.name ?? byWeight.first { $0.name != nil }?.name
            ?? family.label
        let version = byWeight.first { $0.version != nil && ($0.name == nil || $0.name == name) }?.version
            ?? byWeight.first { $0.version != nil }?.version
        let type = byWeight.first { $0.type != nil && ($0.name == nil || $0.name == name) }?.type
            ?? byWeight.first { $0.type != nil }?.type
        var clues: [FPClue] = []
        for vote in byWeight where !clues.contains(vote.clue) { clues.append(vote.clue) }
        return FPSystemResult(family: family, name: name, version: version, deviceType: type,
                              confidence: confidence, clues: clues)
    }

    static func order(_ family: FPSystemFamily) -> Int {
        FPSystemFamily.allCases.firstIndex(of: family) ?? 99
    }

    /// TTL initial probable : 64, 128 ou 255 (le TTL reçu, moins les routeurs traversés).
    public static func initialTTL(_ ttl: Int) -> Int? {
        switch ttl {
        case 1...64: return 64
        case 65...128: return 128
        case 129...255: return 255
        default: return nil
        }
    }

    static func compatible(_ family: FPSystemFamily, ttl: Int) -> Bool {
        switch ttl {
        case 64: return ![.windows, .ciscoIOS, .fortios].contains(family)
        case 128: return family == .windows
        default: return [.fortios, .ciscoIOS, .network, .printer, .embedded, .camera, .bmc, .arubaOS].contains(family)
        }
    }

    /// TTL seul : piste faible.
    static func ttlOnly(_ initial: Int) -> FPSystemResult {
        let clue: FPClue
        let family: FPSystemFamily
        let name: String
        switch initial {
        case 128:
            family = .windows
            name = "Windows"
            clue = FPClue(source: .ttl, observed: "TTL initial 128", conclusion: "probablement Windows", weight: .faible)
        case 64:
            family = .linux
            name = "Linux, macOS ou Unix"
            clue = FPClue(source: .ttl, observed: "TTL initial 64", conclusion: "Linux, macOS, Unix ou embarqué", weight: .faible)
        default:
            family = .network
            name = "Équipement réseau"
            clue = FPClue(source: .ttl, observed: "TTL initial 255", conclusion: "équipement réseau ou embarqué", weight: .faible)
        }
        return FPSystemResult(family: family, name: name, confidence: .faible, clues: [clue])
    }

    // MARK: sysDescr

    /// sysDescr SNMP : « Hardware: Intel64 … Software: Windows Version 6.3 (Build 17763 …) »,
    /// « Linux nas 4.4.180+ … », « FortiGate-60F v7.2.8 », « Cisco IOS Software, … Version 15.2(7)E2 »…
    static func sysDescr(_ descr: String, objectID: String?) -> [FPVote] {
        let text = descr.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let lower = text.lowercased()
        let info = SNMPSysDescr.parse(descr, objectID: objectID)
        let observed = text.count > 90 ? String(text.prefix(88)) + "…" : text
        let vote = { (family: FPSystemFamily, name: String, version: String?, type: DeviceType?) -> FPVote in
            let conclusion = name + (version.map { " \($0)" } ?? "")
            return FPVote(family: family, name: name, version: version, type: type,
                          clue: FPClue(source: .snmp, observed: observed, conclusion: conclusion, weight: .forte))
        }
        if lower.contains("windows") {
            var release: String?
            if let range = lower.range(of: "build ") {
                let digits = lower[range.upperBound...].prefix { $0.isNumber }
                release = Int(digits).flatMap(FPServiceRules.windowsRelease)
            }
            return [vote(.windows, "Windows", release, nil)]
        }
        if lower.hasPrefix("fortigate") || lower.hasPrefix("fortiwifi") {
            return [vote(.fortios, "FortiGate", info.version, .routeur)]
        }
        if lower.hasPrefix("fortiap") { return [vote(.fortios, "FortiAP", info.version, .pointAcces)] }
        if lower.hasPrefix("fortiswitch") { return [vote(.fortios, "FortiSwitch", info.version, .switch)] }
        if lower.contains("routeros") { return [vote(.routeros, "MikroTik RouterOS", info.version, .routeur)] }
        if lower.contains("cisco nx-os") { return [vote(.ciscoIOS, "Cisco NX-OS", info.version, .switch)] }
        if lower.contains("cisco adaptive security") { return [vote(.ciscoIOS, "Cisco ASA", info.version, .routeur)] }
        if lower.contains("cisco ios") { return [vote(.ciscoIOS, lower.contains("ios xe") || lower.contains("ios-xe") ? "Cisco IOS XE" : "Cisco IOS", info.version, nil)] }
        if lower.contains("junos") || lower.contains("juniper") { return [vote(.junos, "Junos", info.version, nil)] }
        if lower.contains("aruba") || lower.contains("procurve") { return [vote(.arubaOS, "ArubaOS", info.version, nil)] }
        if lower.hasPrefix("hp ethernet") || lower.contains("jetdirect") || lower.hasPrefix("brother nc-")
            || ["laserjet", "officejet", "ricoh", "lexmark", "xerox", "kyocera", "epson"].contains(where: lower.contains) {
            let name = info.vendor.map { "Imprimante \($0)" } ?? "Imprimante"
            return [vote(.printer, name, info.version.map { "· micrologiciel \($0)" }, .imprimante)]
        }
        if lower.contains("vmware esxi") { return [vote(.esxi, "VMware ESXi", info.version, .serveur)] }
        if lower.hasPrefix("darwin") { return [vote(.macos, "macOS", nil, .poste)] }
        if lower.contains("pfsense") { return [vote(.bsd, "pfSense", nil, .routeur)] }
        if lower.contains("opnsense") { return [vote(.bsd, "OPNsense", nil, .routeur)] }
        if lower.hasPrefix("freebsd") { return [vote(.bsd, "FreeBSD", word(2, text), nil)] }
        if lower.contains("edgeos") || lower.contains("edgeswitch") || lower.hasPrefix("uap") || lower.contains("unifi") {
            return [vote(.ubiquiti, "Ubiquiti", info.version, nil)]
        }
        if info.vendor == "Synology" || lower.contains("synology") || lower.contains("diskstation") {
            return [vote(.dsm, "Synology DSM", info.version, .serveur)]
        }
        if lower.hasPrefix("linux") {
            // « Linux nas 4.4.180+ #42962 … » : noyau en troisième mot.
            return [vote(.linux, "Linux", word(2, text).map { "(noyau \($0))" }, nil)]
        }
        return []
    }

    static func word(_ index: Int, _ text: String) -> String? {
        let words = text.split(separator: " ")
        return words.count > index ? String(words[index]) : nil
    }

    // MARK: TXT mDNS

    /// TXT des services Bonjour : « ty » (imprimantes IPP), « vendor » et « model » (Synology),
    /// « model » (Apple _device-info), « md » (Chromecast), « osxvers ».
    static func mdns(_ txt: [String: String]) -> [FPVote] {
        var result: [FPVote] = []
        let lowerKeys = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func clue(_ key: String, _ conclusion: String, _ weight: FPConfidence) -> FPClue {
            FPClue(source: .mdns, observed: "\(key)=\(lowerKeys[key] ?? "")", conclusion: conclusion, weight: weight)
        }
        if let ty = lowerKeys["ty"] ?? lowerKeys["usb_mdl"] ?? lowerKeys["product"] {
            let key = lowerKeys["ty"] != nil ? "ty" : (lowerKeys["usb_mdl"] != nil ? "usb_mdl" : "product")
            let model = ty.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            result.append(FPVote(family: .printer, name: "Imprimante", type: .imprimante,
                                 clue: clue(key, "imprimante " + model, .forte)))
        }
        if let vendor = lowerKeys["vendor"]?.lowercased() {
            if vendor.contains("synology") {
                var version: String?
                if let major = lowerKeys["version_major"], let minor = lowerKeys["version_minor"] {
                    version = "\(major).\(minor)" + (lowerKeys["version_build"].map { " (build \($0))" } ?? "")
                }
                result.append(FPVote(family: .dsm, name: "Synology DSM", version: version, type: .serveur,
                                     clue: clue("vendor", "NAS Synology" + (lowerKeys["model"].map { " \($0)" } ?? ""), .forte)))
            } else if vendor.contains("qnap") {
                result.append(FPVote(family: .qts, name: "QNAP QTS", type: .serveur, clue: clue("vendor", "NAS QNAP", .forte)))
            }
        }
        if let osx = lowerKeys["osxvers"], let darwin = Int(osx) {
            let version = darwin >= 20 ? String(darwin - 9) : nil
            result.append(FPVote(family: .macos, name: "macOS", version: version, type: .poste,
                                 clue: clue("osxvers", "macOS" + (version.map { " \($0)" } ?? ""), .forte)))
        } else if let model = lowerKeys["model"], model.range(of: "^(Mac|iMac|MacBook|Macmini|MacPro)", options: .regularExpression) != nil {
            result.append(FPVote(family: .macos, name: "macOS", type: .poste, clue: clue("model", "Mac (\(model))", .forte)))
        }
        if let md = lowerKeys["md"], md.lowercased().contains("chromecast") || md.lowercased().contains("google") {
            result.append(FPVote(family: .embedded, name: "Google Cast", type: .iot, clue: clue("md", "Google Cast (\(md))", .forte)))
        }
        return result
    }

    // MARK: Ports et fabricant (indices d'appoint)

    static func ports(_ open: [UInt16]) -> [FPVote] {
        let set = Set(open)
        var result: [FPVote] = []
        func clue(_ observed: String, _ conclusion: String, _ weight: FPConfidence) -> FPClue {
            FPClue(source: .ports, observed: observed, conclusion: conclusion, weight: weight)
        }
        if set.contains(135), set.contains(445) {
            result.append(FPVote(family: .windows, name: "Windows", clue: clue("135 et 445", "RPC et SMB de Windows", .moyenne)))
        } else if set.contains(3389) {
            result.append(FPVote(family: .windows, name: "Windows", clue: clue("3389", "bureau à distance (Windows)", .faible)))
        }
        if set.contains(541) { result.append(FPVote(family: .fortios, clue: clue("541", "FortiManager / FortiGuard (Fortinet)", .moyenne))) }
        if set.contains(8291) { result.append(FPVote(family: .routeros, name: "MikroTik RouterOS", type: .routeur, clue: clue("8291", "Winbox (MikroTik)", .moyenne))) }
        if set.contains(902) { result.append(FPVote(family: .esxi, name: "VMware ESXi", clue: clue("902", "VMware (ESXi)", .faible))) }
        if set.contains(5000), set.contains(5001) {
            result.append(FPVote(family: .dsm, name: "Synology DSM", clue: clue("5000 et 5001", "administration DSM (Synology)", .faible)))
        }
        if set.contains(9100) || set.contains(515) {
            result.append(FPVote(family: .printer, name: "Imprimante", type: .imprimante,
                                 clue: clue(set.contains(9100) ? "9100" : "515", "impression (JetDirect, LPD)", .moyenne)))
        }
        if set.contains(554) || set.contains(37777) {
            result.append(FPVote(family: .camera, name: "Caméra IP", type: .camera, clue: clue(set.contains(554) ? "554" : "37777", "flux vidéo (RTSP)", .faible)))
        }
        return result
    }

    /// Fabricants dont le système est sans ambiguïté (le fabricant seul reste un indice moyen).
    static func vendor(_ vendor: String) -> [FPVote] {
        let lower = vendor.lowercased()
        let rules: [(String, FPSystemFamily, String)] = [
            ("fortinet", .fortios, "FortiOS"), ("synology", .dsm, "Synology DSM"), ("qnap", .qts, "QNAP QTS"),
            ("mikrotik", .routeros, "MikroTik RouterOS"), ("routerboard", .routeros, "MikroTik RouterOS"),
            ("ubiquiti", .ubiquiti, "Ubiquiti"), ("hikvision", .camera, "Caméra Hikvision"),
            ("dahua", .camera, "Caméra Dahua"), ("axis", .camera, "Caméra Axis"),
            ("brother", .printer, "Imprimante Brother"), ("lexmark", .printer, "Imprimante Lexmark"),
            ("kyocera", .printer, "Imprimante Kyocera"), ("ricoh", .printer, "Imprimante Ricoh"),
            ("xerox", .printer, "Imprimante Xerox"),
        ]
        let words = Set(lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        guard let match = rules.first(where: { words.contains($0.0) }) else { return [] }
        return [FPVote(family: match.1, name: match.2,
                       clue: FPClue(source: .vendor, observed: vendor, conclusion: match.2, weight: .moyenne))]
    }
}
