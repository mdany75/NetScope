import Foundation

/// Un champ résumé de la réponse Whois (« Organisation : Google LLC »).
public struct WhoisField: Hashable, Sendable, Identifiable {
    public var key: String
    public var value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct WhoisResult: Sendable {
    public var target: String
    public var raw: String
    public var fields: [WhoisField]
    public var durationMs: Double
}

/// Interrogation Whois par /usr/bin/whois (adresse IP, ASN ou domaine).
public enum Whois {
    public static let executable = "/usr/bin/whois"

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// Cible acceptée : lettres, chiffres, « . », « - », « : », « _ » ; jamais d'option (« -… »).
    public static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_/"))
        guard !trimmed.isEmpty, trimmed.count <= 253, !trimmed.hasPrefix("-"),
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw ToolError.invalidInput("Saisir une adresse IP, un ASN (AS15169) ou un domaine.")
        }
        return trimmed
    }

    public static func query(_ text: String, timeout: TimeInterval = 20) async throws -> WhoisResult {
        let target = try validate(text)
        let start = Date()
        let raw = try await ToolProcess.run(executable, [target], timeout: timeout)
        return WhoisResult(target: target, raw: raw, fields: summarize(raw),
                           durationMs: Date().timeIntervalSince(start) * 1000)
    }

    /// Champs clés, dans l'ordre d'affichage ; seuls les champs trouvés sont renvoyés.
    public static func summarize(_ raw: String) -> [WhoisField] {
        var values: [String: [String]] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("%"), !text.hasPrefix("#"), let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, !key.contains(" http") else { continue }
            values[key, default: []].append(value)
        }
        func first(_ keys: [String]) -> String? {
            for key in keys { if let value = values[key]?.first { return value } }
            return nil
        }
        var fields: [WhoisField] = []
        func add(_ label: String, _ keys: [String]) {
            if let value = first(keys) { fields.append(WhoisField(key: label, value: value)) }
        }
        add("Organisation", ["orgname", "organization", "org-name", "registrant organization", "owner", "descr", "netname"])
        add("ASN", ["originas", "origin", "aut-num", "asnumber"])
        add("Bloc", ["cidr", "route", "inetnum", "netrange", "inet6num"])
        add("Pays", ["country", "registrant country"])
        if let registry = registry(in: raw) { fields.append(WhoisField(key: "Registre", value: registry)) }
        add("Bureau d’enregistrement", ["registrar"])
        add("Création", ["regdate", "creation date", "created"])
        add("Expiration", ["registry expiry date", "registrar registration expiration date", "expires"])
        add("Serveurs de noms", ["name server", "nserver"])
        add("Contact abus", ["orgabuseemail", "abuse-mailbox", "registrar abuse contact email"])
        return fields
    }

    /// Registre régional d'après le texte (ARIN, RIPE…).
    static func registry(in raw: String) -> String? {
        let upper = raw.uppercased()
        for (marker, name) in [("ARIN.NET", "ARIN"), ("RIPE.NET", "RIPE NCC"), ("APNIC.NET", "APNIC"),
                               ("LACNIC.NET", "LACNIC"), ("AFRINIC.NET", "AFRINIC")] where upper.contains(marker) {
            return name
        }
        return nil
    }
}
