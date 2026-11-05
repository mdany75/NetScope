import Foundation

// Parcours d'une sous-arborescence SNMP (note 59), commun à la v2c et à la v3 : GetBulk (ou GetNext
// pour les agents v1 et le Navigateur SNMP), arrêt à la fin de la sous-arborescence, à endOfMibView,
// à la limite de lignes ou sur annulation. La logique ne touche pas au réseau : la requête est
// fournie par l'appelant (client UDP, agent en mémoire des tests et de la démonstration).

/// Manière de parcourir : GetBulk (v2c et v3, rapide) ou GetNext (une ligne par requête).
public enum SNMPWalkMode: Hashable, Sendable {
    case bulk(maxRepetitions: Int)
    case getNext

    public static let defaultBulk = SNMPWalkMode.bulk(maxRepetitions: 25)

    public var label: String {
        switch self {
        case .bulk: return "GETBULK"
        case .getNext: return "GETNEXT"
        }
    }
}

/// Pourquoi un parcours s'est arrêté.
public enum SNMPWalkEnd: String, Hashable, Sendable {
    /// Première ligne hors de la sous-arborescence demandée.
    case subtree
    /// L'agent n'a plus rien après (endOfMibView, ou noSuchName d'un agent v1).
    case endOfMib
    /// Limite de lignes atteinte : il en reste peut-être.
    case limit
    /// L'agent a renvoyé un OID qui ne progresse pas (agent défectueux) : arrêt pour ne pas boucler.
    case notIncreasing

    public var label: String {
        switch self {
        case .subtree: return "fin de la sous-arborescence"
        case .endOfMib: return "fin de la MIB de l’agent"
        case .limit: return "limite de lignes atteinte"
        case .notIncreasing: return "OID qui ne progresse pas (agent défectueux)"
        }
    }
}

public struct SNMPWalkResult: Hashable, Sendable {
    public var binds: [SNMPVarBind]
    public var end: SNMPWalkEnd
    /// Requêtes envoyées (une par GetBulk ou GetNext, renvois exclus).
    public var requests: Int

    public init(binds: [SNMPVarBind], end: SNMPWalkEnd, requests: Int) {
        self.binds = binds
        self.end = end
        self.requests = requests
    }

    public var truncated: Bool { end == .limit }
}

public enum SNMPWalker {
    /// Parcourt `root`. `fetch` envoie une PDU (GetBulk ou GetNext) et rend la réponse, sans
    /// vérifier error-status (ce parcours s'en charge : tooBig réduit la rafale, noSuchName termine).
    /// `onBatch` reçoit les lignes utiles de chaque réponse, dans l'ordre.
    public static func walk(_ root: SNMPOID, mode: SNMPWalkMode, limit: Int = 20_000,
                            onBatch: (@Sendable ([SNMPVarBind]) -> Void)? = nil,
                            fetch: (SNMPPDU) async throws -> SNMPPDU) async throws -> SNMPWalkResult {
        let limit = max(1, limit)
        var result: [SNMPVarBind] = []
        var current = root
        var requests = 0
        var repetitions: Int
        switch mode {
        case .bulk(let maxRepetitions): repetitions = min(max(1, maxRepetitions), 200)
        case .getNext: repetitions = 1
        }
        while true {
            try Task.checkCancellation()
            let requestID = SNMPClient.newRequestID()
            let pdu: SNMPPDU
            switch mode {
            case .bulk:
                // Pas plus que ce qui reste à lire (plus une ligne, pour savoir s'il en reste).
                pdu = .getBulk(requestID: requestID, maxRepetitions: min(repetitions, limit - result.count + 1), oids: [current])
            case .getNext:
                pdu = SNMPPDU(type: .getNextRequest, requestID: requestID, varbinds: [SNMPVarBind(oid: current)])
            }
            let response = try await fetch(pdu)
            requests += 1
            if response.errorStatus == SNMPErrorStatus.tooBig.rawValue, case .bulk = mode, repetitions > 1 {
                repetitions = max(1, repetitions / 2)
                continue
            }
            if response.errorStatus == SNMPErrorStatus.noSuchName.rawValue {
                return finish(result, .endOfMib, requests)
            }
            if response.errorStatus != 0 {
                throw SNMPError.agent(status: response.errorStatus, index: response.errorIndex)
            }
            guard !response.varbinds.isEmpty else { return finish(result, .endOfMib, requests) }
            var batch: [SNMPVarBind] = []
            var end: SNMPWalkEnd?
            for bind in response.varbinds {
                if bind.value == .endOfMibView { end = .endOfMib; break }
                if !bind.oid.hasPrefix(root) { end = .subtree; break }
                if bind.oid <= current { end = .notIncreasing; break }
                current = bind.oid
                // noSuchObject ou noSuchInstance dans un parcours : ligne vide, ignorée.
                if bind.value.isException { continue }
                if result.count + batch.count >= limit { end = .limit; break }
                batch.append(bind)
            }
            if !batch.isEmpty {
                result += batch
                onBatch?(batch)
            }
            if let end { return finish(result, end, requests) }
        }
    }

    private static func finish(_ binds: [SNMPVarBind], _ end: SNMPWalkEnd, _ requests: Int) -> SNMPWalkResult {
        SNMPWalkResult(binds: binds, end: end, requests: requests)
    }
}

// MARK: - Agent en mémoire

/// Agent SNMP simulé en mémoire : répond à GET, GETNEXT et GETBULK d'après une table fixe.
/// Sert aux tests sans réseau et à la démonstration (--demo) du Navigateur SNMP.
public struct SNMPTableAgent: Sendable {
    public let rows: [SNMPVarBind]
    /// Au-delà de ce nombre de liaisons, la réponse est « tooBig » (simulation d'un datagramme trop gros).
    public var maxBindsPerResponse: Int?

    public init(_ rows: [SNMPVarBind], maxBindsPerResponse: Int? = nil) {
        var seen = Set<SNMPOID>()
        self.rows = rows.sorted { $0.oid < $1.oid }.filter { seen.insert($0.oid).inserted }
        self.maxBindsPerResponse = maxBindsPerResponse
    }

    /// Première ligne strictement après `oid` (recherche dichotomique), ou endOfMibView.
    public func next(after oid: SNMPOID) -> SNMPVarBind {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].oid <= oid { low = middle + 1 } else { high = middle }
        }
        return low < rows.count ? rows[low] : SNMPVarBind(oid: oid, value: .endOfMibView)
    }

    /// Valeur d'un GET : la ligne, sinon noSuchInstance (l'objet existe avec d'autres index) ou noSuchObject.
    public func value(at oid: SNMPOID) -> SNMPValue {
        if let row = rows.first(where: { $0.oid == oid }) { return row.value }
        guard oid.components.count > 1 else { return .noSuchObject }
        let object = SNMPOID(Array(oid.components.dropLast()))
        return rows.contains { $0.oid.hasPrefix(object) } ? .noSuchInstance : .noSuchObject
    }

    public func answer(_ pdu: SNMPPDU) -> SNMPPDU {
        var binds: [SNMPVarBind] = []
        switch pdu.type {
        case .getRequest:
            binds = pdu.varbinds.map { SNMPVarBind(oid: $0.oid, value: value(at: $0.oid)) }
        case .getNextRequest:
            binds = pdu.varbinds.map { next(after: $0.oid) }
        case .getBulkRequest:
            let nonRepeaters = min(max(0, pdu.errorStatus), pdu.varbinds.count)
            binds = pdu.varbinds.prefix(nonRepeaters).map { next(after: $0.oid) }
            let repeaters = Array(pdu.varbinds.dropFirst(nonRepeaters))
            var cursors = repeaters.map(\.oid)
            for _ in 0..<max(1, pdu.errorIndex) where !cursors.isEmpty {
                var allEnded = true
                for (position, cursor) in cursors.enumerated() {
                    let bind = next(after: cursor)
                    binds.append(bind)
                    if bind.value != .endOfMibView { allEnded = false }
                    cursors[position] = bind.oid
                }
                if allEnded { break }
            }
        default:
            return SNMPPDU(type: .response, requestID: pdu.requestID, errorStatus: SNMPErrorStatus.genErr.rawValue,
                           errorIndex: 0, varbinds: pdu.varbinds)
        }
        if let limit = maxBindsPerResponse, binds.count > limit {
            return SNMPPDU(type: .response, requestID: pdu.requestID, errorStatus: SNMPErrorStatus.tooBig.rawValue,
                           errorIndex: 0, varbinds: [])
        }
        return SNMPPDU(type: .response, requestID: pdu.requestID, varbinds: binds)
    }
}
