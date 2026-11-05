import Foundation

// Note 73 : déroulement d'une action sur un port (cycle PoE en SNMP : coupure, attente, remise),
// suivi du retour de l'appareil (ping et état du lien) et trace de l'action (journal de l'app,
// chronologie de l'inventaire). L'horloge, l'attente, le ping et l'écriture sont injectés : tout
// se teste sans réseau.

/// Étape en cours, affichée sous les boutons.
public enum PortActionPhase: Equatable, Sendable {
    /// Requête envoyée à la FortiGate.
    case sending
    /// SET pethPsePortAdminEnable = false.
    case poweringOff
    /// PoE coupé, remise dans `remaining` secondes.
    case waitingOff(remaining: Int)
    /// SET pethPsePortAdminEnable = true (avec l'essai en cours).
    case poweringOn(attempt: Int)
    /// Attente du retour de l'appareil : secondes écoulées depuis la coupure, état du lien (nil : inconnu).
    case waitingReturn(elapsed: Int, linkUp: Bool?)
    case finished

    public var label: String {
        switch self {
        case .sending: return "Envoi de la demande…"
        case .poweringOff: return "Coupure du PoE…"
        case .waitingOff(let remaining): return "PoE coupé · remise dans \(remaining)\u{00A0}s"
        case .poweringOn(let attempt): return attempt > 1 ? "Remise du PoE (essai \(attempt))…" : "Remise du PoE…"
        case .waitingReturn(let elapsed, let linkUp):
            let link: String
            switch linkUp {
            case true?: link = " · lien rétabli"
            case false?: link = " · lien coupé"
            case nil: link = ""
            }
            return "Attente du retour de l’appareil · \(PortActionFormat.seconds(elapsed))\(link)"
        case .finished: return "Terminé"
        }
    }
}

/// Retour de l'appareil après l'action.
public enum PortActionReturn: Codable, Equatable, Sendable {
    /// L'appareil a cessé de répondre puis est revenu, N secondes après la coupure.
    case returned(seconds: Int)
    /// Il n'a jamais cessé de répondre (alimenté autrement, ou action sans effet visible).
    case neverLost
    /// Toujours muet au bout de l'attente maximale.
    case notBack(after: Int)
    /// Pas d'adresse IP connue : seul le lien du port a pu être suivi.
    case notFollowed
    /// L'appareil ne répondait déjà pas au ping avant l'action : seul le lien a pu être suivi.
    case noPingReply
    /// Ping indisponible sur ce Mac : seul le lien a pu être suivi.
    case pingUnavailable

    public var label: String {
        switch self {
        case .returned(let seconds): return "revenu en \(PortActionFormat.seconds(seconds))"
        case .neverLost: return "toujours joignable (aucune coupure vue)"
        case .notBack(let after): return "pas revenu après \(PortActionFormat.seconds(after))"
        case .notFollowed: return "retour non suivi (adresse IP inconnue)"
        case .noPingReply: return "retour non suivi (l’appareil ne répondait pas au ping avant l’action)"
        case .pingUnavailable: return "retour non suivi (ping indisponible)"
        }
    }

    public var isProblem: Bool {
        if case .notBack = self { return true }
        return false
    }
}

public enum PortActionFormat {
    /// « 38 s », « 2 min 05 s ».
    public static func seconds(_ value: Int) -> String {
        let v = max(0, value)
        if v < 60 { return "\(v)\u{00A0}s" }
        if v % 60 == 0 { return "\(v / 60)\u{00A0}min" }
        return "\(v / 60)\u{00A0}min\u{00A0}" + String(format: "%02d", v % 60) + "\u{00A0}s"
    }
}

/// Exécution des étapes.
public enum PortActionRunner {
    /// Nombre d'essais pour rallumer le PoE : un port laissé coupé est le pire résultat possible.
    public static let powerOnAttempts = 3

    /// Cycle PoE en SNMP : false, attente `offSeconds`, true. La remise est tentée même si la tâche
    /// est annulée pendant l'attente, et répétée jusqu'à trois fois ; si elle échoue toujours,
    /// l'erreur `poeLeftOff` le dit clairement.
    public static func snmpPoECycle(writer: PoEPortWriter, offSeconds: Int,
                                    sleep: @escaping @Sendable (Double) async -> Void,
                                    phase: @escaping @Sendable (PortActionPhase) async -> Void) async throws {
        await phase(.poweringOff)
        try await writer.setPoE(enabled: false)
        let total = min(max(offSeconds, PortActionSettings.offRange.lowerBound), PortActionSettings.offRange.upperBound)
        for remaining in stride(from: total, to: 0, by: -1) {
            await phase(.waitingOff(remaining: remaining))
            await sleep(1)
        }
        var lastError: Error?
        for attempt in 1...powerOnAttempts {
            await phase(.poweringOn(attempt: attempt))
            do {
                try await writer.setPoE(enabled: true)
                return
            } catch {
                lastError = error
                if attempt < powerOnAttempts { await sleep(2) }
            }
        }
        let detail = (lastError as? LocalizedError)?.errorDescription ?? lastError.map { "\($0)" } ?? "erreur inconnue"
        throw PortActionError.poeLeftOff(detail)
    }

    /// Suit le retour de l'appareil : un ping toutes les `interval` secondes (et l'état du lien
    /// toutes les trois sondes) jusqu'à ce qu'il réponde après avoir cessé de répondre. Sans
    /// aucune perte pendant `graceSeconds`, l'appareil est déclaré « toujours joignable ».
    /// `respondedBefore` : réponse au ping juste avant l'action (false : l'appareil filtre l'ICMP,
    /// son silence ne dit rien ; seul le lien est alors suivi).
    public static func followUp(ip: IPv4Address?, pinger: ScanPinging?, linkProbe: (@Sendable () async -> Bool?)?,
                                start: Date, limitSeconds: Int, interval: Double = 2, graceSeconds: Int = 20,
                                respondedBefore: Bool? = nil,
                                now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) async -> Void,
                                progress: @escaping @Sendable (Int, Bool?) async -> Void) async -> PortActionReturn {
        let unfollowed: PortActionReturn = ip == nil ? .notFollowed : (pinger == nil ? .pingUnavailable : .noPingReply)
        let pingIP = respondedBefore == false ? nil : ip
        let pingTool = pingIP == nil ? nil : pinger
        var lostSeen = false
        var linkUp: Bool?
        var iteration = 0
        while true {
            let elapsed = Int(now().timeIntervalSince(start).rounded())
            if Task.isCancelled { return pingIP == nil || pingTool == nil ? unfollowed : .notBack(after: elapsed) }
            if pingIP != nil, pingTool != nil, elapsed >= limitSeconds { return .notBack(after: elapsed) }
            if iteration % 3 == 0, let linkProbe { linkUp = await linkProbe() }
            iteration += 1
            await progress(elapsed, linkUp)
            if let pingIP, let pingTool {
                let reply = await pingTool.ping(pingIP, timeout: .seconds(1))
                let after = Int(now().timeIntervalSince(start).rounded())
                if reply != nil {
                    if lostSeen { return .returned(seconds: after) }
                    if after >= graceSeconds { return .neverLost }
                } else {
                    lostSeen = true
                }
                if after >= limitSeconds { return .notBack(after: after) }
            } else {
                // Sans adresse : on suit le lien seulement, jusqu'à ce qu'il revienne.
                guard linkProbe != nil else { return unfollowed }
                if (linkUp == true && elapsed >= 2) || elapsed >= limitSeconds { return unfollowed }
            }
            await sleep(interval)
        }
    }
}

/// Trace d'une action (journal de l'app, chronologie de l'inventaire). Aucun secret.
public struct PortActionRecord: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: PortActionKind
    public var switchName: String
    public var portName: String
    public var deviceName: String?
    public var deviceIP: IPv4Address?
    public var deviceMAC: MACAddress?
    /// « FortiGate « Siège » (API REST) », « SNMP en écriture (…) ».
    public var channel: String
    public var success: Bool
    public var errorMessage: String?
    public var returned: PortActionReturn?
    /// Démonstration : rien n'a été envoyé.
    public var simulated: Bool

    public init(date: Date, kind: PortActionKind, target: PortActionTarget, channel: String, success: Bool,
                errorMessage: String? = nil, returned: PortActionReturn? = nil, simulated: Bool = false) {
        self.date = date
        self.kind = kind
        switchName = target.switchName
        portName = target.portName
        deviceName = target.deviceName
        deviceIP = target.deviceIP
        deviceMAC = target.deviceMAC
        self.channel = channel
        self.success = success
        self.errorMessage = errorMessage
        self.returned = returned
        self.simulated = simulated
    }

    /// « réussi · revenu en 38 s », « échec : … ».
    public var resultText: String {
        if success {
            return "réussi" + (returned.map { " · \($0.label)" } ?? "")
        }
        return "échec\u{00A0}: " + (errorMessage ?? "erreur inconnue")
    }

    /// Ligne du journal de l'app (module « Actions sur les ports »).
    public var logLine: String {
        var device = deviceName ?? deviceIP?.description ?? "appareil inconnu"
        if let ip = deviceIP, let name = deviceName, name != ip.description { device += " (\(ip))" }
        let demo = simulated ? " · démonstration, rien n’a été envoyé" : ""
        return "\(kind.shortLabel) · \(switchName) · port \(portName) · \(device) · par \(channel) · \(resultText)\(demo)"
    }

    /// Module du journal.
    public static let logModule = "Actions sur les ports"

    /// Événement de la chronologie de la fiche `key`.
    public func inventoryEvent(key: String) -> InvEvent {
        let problem = !success || returned?.isProblem == true
        var detail = "\(switchName) · port \(portName) · par \(channel) · \(resultText)"
        if simulated { detail += " · démonstration" }
        return InvEvent(date: date, kind: .actionPort, severity: problem ? .alerte : .info, key: key,
                        ip: deviceIP ?? IPv4Address(0), title: kind.shortLabel + (success ? "" : " échoué"),
                        detail: detail, status: .accepte, statusDate: date)
    }

    /// Fiche d'inventaire de l'appareil : par sa MAC, sinon par son adresse.
    public var inventoryKey: String? {
        if let deviceMAC { return InventoryStore.key(mac: deviceMAC) }
        return deviceIP.map { InventoryStore.key(ip: $0) }
    }
}

extension InventoryStore {
    /// Note 73 : ajoute une action sur un port à la chronologie de la fiche ; faux si la fiche
    /// n'existe pas (rien n'est créé pour une action).
    @discardableResult
    public mutating func recordPortAction(_ event: InvEvent) -> Bool {
        guard record(event.key) != nil else { return false }
        events.append(event)
        return true
    }
}
