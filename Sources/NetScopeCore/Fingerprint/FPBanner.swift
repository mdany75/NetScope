import Foundation

/// Réponses brutes lues par le scan de ports → observations (pur, testé sur des réponses recopiées).
public enum FPBanner {
    /// Bannière d'un service qui parle le premier (SSH, FTP, SMTP, Telnet, VNC, MySQL).
    public static func listenObservation(port: UInt16, data: Data, at date: Date = Date()) -> FPServiceObservation? {
        var bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        if port == 3306, let version = mysqlVersion(bytes) {
            return FPServiceObservation(port: port, banner: version, observedAt: date)
        }
        bytes = stripTelnet(bytes)
        guard let line = firstLine(bytes) else { return nil }
        return FPServiceObservation(port: port, banner: String(line.prefix(160)), observedAt: date)
    }

    /// Réponse HTTP (HEAD ou GET) : ligne d'état, Server, X-Powered-By, realm et titre éventuel.
    public static func httpObservation(port: UInt16, data: Data, tls: Bool = false, at date: Date = Date()) -> FPServiceObservation? {
        let text = String(decoding: data, as: UTF8.self)
        let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let head = headerEnd.map { String(text[..<$0.lowerBound]) } ?? text
        let lines = head.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let status = lines.first, status.hasPrefix("HTTP/") else { return nil }
        var observation = FPServiceObservation(port: port, httpStatus: printable(status), tls: tls, observedAt: date)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = printable(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }
            switch key {
            case "server": observation.httpServer = observation.httpServer ?? String(value.prefix(160))
            case "x-powered-by": observation.httpPoweredBy = observation.httpPoweredBy ?? String(value.prefix(80))
            case "www-authenticate": observation.httpRealm = observation.httpRealm ?? realm(value)
            default: break
            }
        }
        if let headerEnd {
            let body = String(text[headerEnd.upperBound...])
            observation.httpTitle = HTTPProbe.extractTitle(from: body)
        }
        return observation
    }

    /// realm="HP LaserJet M404" → HP LaserJet M404.
    static func realm(_ header: String) -> String? {
        guard let range = header.range(of: "realm=", options: .caseInsensitive) else { return nil }
        var value = header[range.upperBound...]
        if value.first == "\"" {
            value = value.dropFirst()
            value = value.prefix { $0 != "\"" }
        } else {
            value = value.prefix { $0 != "," }
        }
        let text = String(value).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(120))
    }

    /// Paquet d'accueil MySQL : longueur (3), numéro (1), protocole 10, version terminée par 0.
    static func mysqlVersion(_ bytes: [UInt8]) -> String? {
        guard bytes.count > 6, bytes[4] == 0x0A else { return nil }
        let version = bytes[5...].prefix { $0 != 0 }
        guard !version.isEmpty, version.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: version, as: UTF8.self)
    }

    /// Retire les négociations Telnet (IAC 0xFF, commande, option).
    static func stripTelnet(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xFF, index + 1 < bytes.count {
                let command = bytes[index + 1]
                if command == 0xFA, let end = bytes[index...].firstIndex(of: 0xF0) {
                    index = end + 1
                } else {
                    index += (251...254).contains(command) ? 3 : 2
                }
                continue
            }
            result.append(bytes[index])
            index += 1
        }
        return result
    }

    static func firstLine(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.components(separatedBy: CharacterSet.newlines).map(printable).first { !$0.isEmpty }
    }

    static func printable<S: StringProtocol>(_ text: S) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xFFFD }))
            .trimmingCharacters(in: .whitespaces)
    }
}
