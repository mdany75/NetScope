import Foundation

/// Test d'un identifiant SNMP (Réglages › Identifiants) : lecture de sysName, sysDescr et sysUpTime
/// sur une adresse choisie, ou erreur expliquée.
public enum SNMPCredentialTest {
    public static let sysDescr: SNMPOID = "1.3.6.1.2.1.1.1.0"
    public static let sysUpTime: SNMPOID = "1.3.6.1.2.1.1.3.0"
    public static let sysName: SNMPOID = "1.3.6.1.2.1.1.5.0"

    /// Résultat réussi.
    public struct Success: Equatable, Sendable {
        public var sysName: String
        public var sysDescr: String
        /// Centièmes de seconde depuis le démarrage de l'agent.
        public var uptimeTicks: UInt32?
        public var milliseconds: Int

        public init(sysName: String, sysDescr: String, uptimeTicks: UInt32?, milliseconds: Int) {
            self.sysName = sysName
            self.sysDescr = sysDescr
            self.uptimeTicks = uptimeTicks
            self.milliseconds = milliseconds
        }

        /// « 12 j 4 h 07 min » (ou nil si l'agent ne l'a pas donné).
        public var uptimeText: String? {
            guard let uptimeTicks else { return nil }
            let seconds = Int(uptimeTicks / 100)
            let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
            if days > 0 { return "\(days)\u{00A0}j \(hours)\u{00A0}h \(String(format: "%02d", minutes))\u{00A0}min" }
            if hours > 0 { return "\(hours)\u{00A0}h \(String(format: "%02d", minutes))\u{00A0}min" }
            return "\(minutes)\u{00A0}min \(seconds % 60)\u{00A0}s"
        }

        /// Première ligne de sysDescr (souvent très longue).
        public var shortDescr: String {
            sysDescr.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    /// Catégorie d'échec, pour la couleur et le conseil.
    public enum Failure: Equatable, Sendable {
        case timeout
        case portClosed
        case communityRejected
        case unknownUser
        case authentication
        case decryption
        case securityLevel
        case configuration(String)
        case other(String)
    }

    public struct Outcome: Equatable, Sendable {
        public var success: Success?
        public var failure: Failure?
        /// Phrase complète affichée sous l'identifiant.
        public var message: String

        public init(success: Success?, failure: Failure?, message: String) {
            self.success = success
            self.failure = failure
            self.message = message
        }

        /// Texte à afficher (message d'un succès recalculé au besoin).
        public var displayText: String {
            if let success { return message.isEmpty ? SNMPCredentialTest.message(for: success) : message }
            return message
        }
    }

    /// Lecture des valeurs dans les liaisons reçues (dans n'importe quel ordre).
    public static func success(from binds: [SNMPVarBind], milliseconds: Int) -> Success {
        func value(_ oid: SNMPOID) -> SNMPValue? { binds.first { $0.oid == oid }?.value }
        let name = value(sysName).flatMap { $0.isException ? nil : $0.stringValue } ?? ""
        let descr = value(sysDescr).flatMap { $0.isException ? nil : $0.stringValue } ?? ""
        var ticks: UInt32?
        if case .timeTicks(let raw)? = value(sysUpTime) { ticks = raw }
        return Success(sysName: name, sysDescr: descr, uptimeTicks: ticks, milliseconds: milliseconds)
    }

    /// Message d'un test réussi : « Réussi · sysName SW-CORE-01 · Catalyst 9300 · 41 ms ».
    public static func message(for success: Success) -> String {
        var parts = ["Réussi"]
        parts.append(success.sysName.isEmpty ? "sysName vide" : "sysName \(success.sysName)")
        if !success.shortDescr.isEmpty { parts.append(success.shortDescr) }
        if let uptime = success.uptimeText { parts.append("en marche depuis \(uptime)") }
        parts.append("\(success.milliseconds)\u{00A0}ms")
        return parts.joined(separator: " · ")
    }

    /// Analyse d'une erreur du client v2c ou v3 : catégorie et explication pour le technicien.
    public static func explain(_ error: Error, version3: Bool, host: String) -> (Failure, String) {
        if let error = error as? SNMPv3Error {
            switch error {
            case .report(.unknownUserName):
                return (.unknownUser, "Échec · utilisateur inconnu de l’agent \(host) : vérifiez le nom (sensible à la casse) et qu’il existe sur cet équipement.")
            case .report(.wrongDigest), .badResponseDigest:
                return (.authentication, "Échec · authentification refusée par \(host) : mot de passe ou protocole d’authentification (MD5, SHA…) incorrect.")
            case .report(.decryptionError), .responseDecryption:
                return (.decryption, "Échec · déchiffrement impossible : mot de passe ou protocole de confidentialité (DES, AES…) incorrect.")
            case .report(.unsupportedSecLevel):
                return (.securityLevel, "Échec · niveau de sécurité refusé : l’utilisateur existe, mais pas avec ce niveau (essayez authPriv ou authNoPriv).")
            case .report(let other):
                return (.other(other.rawValue), "Échec · \(other.explanation).")
            case .missingUser, .shortPassword:
                return (.configuration(error.localizedDescription), "Échec · \(error.localizedDescription)")
            case .noEngineID:
                return (.other("engineID"), "Échec · \(error.localizedDescription)")
            }
        }
        if let error = error as? SNMPError {
            switch error {
            case .timeout:
                let hint = version3
                    ? "SNMP v3 désactivé, filtré par un pare-feu ou adresse incorrecte."
                    : "Communauté refusée (un agent v2c ignore en silence une mauvaise communauté), SNMP désactivé ou filtré."
                return (.timeout, "Échec · délai dépassé, aucune réponse de \(host) : \(hint)")
            case .unreachable:
                return (.portClosed, "Échec · \(host) refuse le port UDP 161 : aucun agent SNMP n’y écoute.")
            case .emptyCommunity:
                return (.configuration(error.localizedDescription), "Échec · \(error.localizedDescription)")
            case .agent(let status, _):
                if status == SNMPErrorStatus.noAccess.rawValue || status == SNMPErrorStatus.authorizationError.rawValue {
                    return (.communityRejected, "Échec · accès refusé : la communauté (ou l’utilisateur) n’a pas le droit de lire le groupe system.")
                }
                return (.other(error.localizedDescription), "Échec · \(error.localizedDescription)")
            case .socket, .unexpectedResponse, .v3NotSupported:
                return (.other(error.localizedDescription), "Échec · \(error.localizedDescription)")
            }
        }
        return (.other(error.localizedDescription), "Échec · \(error.localizedDescription)")
    }

    /// Test v2c.
    public static func run(host: IPv4Address, community: String, port: UInt16 = 161, timeout: TimeInterval = 2) async -> Outcome {
        let start = Date()
        do {
            let client = SNMPClient(target: SNMPTarget(host: host, port: port, community: community, timeout: timeout, retries: 1))
            let binds = try await client.get([sysName, sysDescr, sysUpTime])
            let result = success(from: binds, milliseconds: elapsed(since: start, timeout: timeout))
            return Outcome(success: result, failure: nil, message: message(for: result))
        } catch {
            let (failure, text) = explain(error, version3: false, host: host.description)
            return Outcome(success: nil, failure: failure, message: text)
        }
    }

    /// Test v3.
    public static func run(host: IPv4Address, credentials: SNMPv3Credentials, port: UInt16 = 161, timeout: TimeInterval = 2) async -> Outcome {
        let start = Date()
        do {
            let client = SNMPv3Client(host: host, port: port, credentials: credentials, timeout: timeout, retries: 1)
            let binds = try await client.get([sysName, sysDescr, sysUpTime])
            let result = success(from: binds, milliseconds: elapsed(since: start, timeout: timeout))
            return Outcome(success: result, failure: nil, message: message(for: result))
        } catch {
            let (failure, text) = explain(error, version3: true, host: host.description)
            return Outcome(success: nil, failure: failure, message: text)
        }
    }

    private static func elapsed(since start: Date, timeout: TimeInterval) -> Int {
        max(1, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }
}
