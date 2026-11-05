import Foundation

// Note 78 (0.26.0) : rapprochement des MAC aléatoires. Un téléphone ou un portable à « adresse
// privée » (MAC administrée localement) change de MAC selon le réseau ou de temps à autre : il
// laisse derrière lui des fiches orphelines. Une fiche à MAC aléatoire est rapprochée d'une autre
// par le même nom d'hôte ou le même numéro de série. Le rapprochement est PROPOSÉ (panneau
// « Doublons probables ») : jamais fusionné automatiquement.

extension InvDuplicate {
    /// Critère d'un rapprochement de MAC aléatoire.
    public enum RandomMACCriterion: String, Sendable, Hashable {
        case hostname, serial
    }
}

public enum InvRandomMAC {
    /// Noms d'hôte trop communs pour identifier un appareil (« iPhone », « android »…).
    public static let genericHostnames: Set<String> = [
        "iphone", "ipad", "android", "localhost", "unknown", "inconnu", "galaxy", "macbook", "macbook-pro", "macbook-air",
        "windows", "desktop", "laptop", "pixel", "esp", "espressif", "host", "device", "client",
    ]

    /// Nom d'hôte ramené à sa partie distinctive : minuscules, sans domaine (« .local », « .bureau.lan »),
    /// sans suffixe de doublon (« -2 », « (2) ») ; nil s'il est trop court, générique ou une adresse IP.
    public static func normalizedHostname(_ text: String?) -> String? {
        guard var name = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty,
              IPv4Address(name) == nil else { return nil }
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        name = name.replacingOccurrences(of: "’", with: "'")
        if let range = name.range(of: #"(\s*\(\d+\)|-\d)$"#, options: .regularExpression) { name.removeSubrange(range) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        guard name.count > 2, !genericHostnames.contains(name) else { return nil }
        return name
    }

    /// Numéro de série d'une fiche (saisi, sinon détecté), normalisé ; nil s'il est trop court.
    public static func serial(of record: InvRecord) -> String? {
        let raw = record.enteredSerial.isEmpty ? (record.detectedHardware?.serialNumber ?? "") : record.enteredSerial
        let serial = InvDetectedHardware.normalizedSerial(raw)
        guard serial.count >= 4, !["0000", "NA", "NONE", "UNKNOWN", "DEFAULTSTRING", "TOBEFILLEDBYOEM"].contains(serial) else { return nil }
        return serial
    }

    /// Paires à proposer : au moins une MAC aléatoire, même nom d'hôte ou même numéro de série,
    /// jamais en ligne en même temps. La fiche gardée est la plus récemment vue.
    public static func matches(in records: [InvRecord]) -> [InvDuplicate] {
        let candidates = records.filter { $0.mac != nil }
        var byHost: [String: [InvRecord]] = [:]
        var bySerial: [String: [InvRecord]] = [:]
        for record in candidates {
            if let host = normalizedHostname(record.hostname) { byHost[host, default: []].append(record) }
            if let serial = serial(of: record) { bySerial[serial, default: []].append(record) }
        }
        var result: [String: InvDuplicate] = [:]
        func propose(_ group: [InvRecord], criterion: InvDuplicate.RandomMACCriterion, value: String) {
            guard group.count > 1, group.contains(where: { $0.mac?.isRandomized == true }) else { return }
            let sorted = group.sorted { ($0.lastSeen, $0.key) > ($1.lastSeen, $1.key) }
            let keep = sorted[0]
            for other in sorted.dropFirst() where keep.mac?.isRandomized == true || other.mac?.isRandomized == true {
                guard !(keep.isOnline && other.isOnline) else { continue }
                let pair = keep.key + "+" + other.key
                guard result[pair] == nil else {
                    // Les deux critères à la fois : le numéro de série, plus sûr, est cité aussi.
                    if criterion == .serial { result[pair]?.reason += " Même numéro de série (\(value))." }
                    continue
                }
                let what = criterion == .hostname ? "même nom d’hôte (\(keep.hostname ?? value))" : "même numéro de série (\(value))"
                let reason = "MAC aléatoire (adresse administrée localement), \(what), jamais en ligne en même temps."
                var duplicate = InvDuplicate(keep: keep.key, absorb: other.key, reason: reason)
                duplicate.randomMAC = criterion
                result[pair] = duplicate
            }
        }
        for (host, group) in byHost { propose(group, criterion: .hostname, value: host) }
        for (serial, group) in bySerial { propose(group, criterion: .serial, value: serial) }
        return result.values.sorted { $0.id < $1.id }
    }
}
