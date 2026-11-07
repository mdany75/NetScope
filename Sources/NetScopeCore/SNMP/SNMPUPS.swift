import Foundation

// Note 98 : onduleurs (UPS) par SNMP : UPS-MIB (RFC 1628), puis les MIB d'APC (PowerNet), d'Eaton
// (XUPS-MIB) et de CyberPower pour ce que la MIB standard ne publie pas (date de remplacement de la
// batterie, date du dernier test, voyant « batterie à changer »). Comme les consommables des
// imprimantes (note 91) : lecture seulement sur demande (bouton de la fiche, sonde de Surveillance),
// analyse pure (`UPSMIB.reading`) testée sur des réponses fixes.

public enum UPSMIBOIDs {
    /// UPS-MIB (RFC 1628) : upsObjects.
    public static let standard: SNMPOID = "1.3.6.1.2.1.33.1"
    /// APC PowerNet : upsObjects (smartUPS).
    public static let apc: SNMPOID = "1.3.6.1.4.1.318.1.1.1"
    /// Eaton / Powerware XUPS-MIB.
    public static let eaton: SNMPOID = "1.3.6.1.4.1.534.1"
    /// CyberPower : ups (cpsMIB).
    public static let cyberPower: SNMPOID = "1.3.6.1.4.1.3808.1.1.1"
    /// Sous-arbres parcourus, dans l'ordre (la MIB standard d'abord).
    public static let roots: [SNMPOID] = [standard, apc, eaton, cyberPower]

    // UPS-MIB.
    static let manufacturer: SNMPOID = "1.3.6.1.2.1.33.1.1.1.0"
    static let model: SNMPOID = "1.3.6.1.2.1.33.1.1.2.0"
    static let batteryStatus: SNMPOID = "1.3.6.1.2.1.33.1.2.1.0"
    static let secondsOnBattery: SNMPOID = "1.3.6.1.2.1.33.1.2.2.0"
    static let minutesRemaining: SNMPOID = "1.3.6.1.2.1.33.1.2.3.0"
    static let chargeRemaining: SNMPOID = "1.3.6.1.2.1.33.1.2.4.0"
    static let batteryTemperature: SNMPOID = "1.3.6.1.2.1.33.1.2.7.0"
    static let inputVoltage: SNMPOID = "1.3.6.1.2.1.33.1.3.3.1.3.1"
    static let outputSource: SNMPOID = "1.3.6.1.2.1.33.1.4.1.0"
    static let outputVoltage: SNMPOID = "1.3.6.1.2.1.33.1.4.4.1.2.1"
    static let outputLoad: SNMPOID = "1.3.6.1.2.1.33.1.4.4.1.5.1"
    static let alarmDescr: SNMPOID = "1.3.6.1.2.1.33.1.6.2.1.2"
    static let wellKnownAlarms: SNMPOID = "1.3.6.1.2.1.33.1.6.3"
    static let testResult: SNMPOID = "1.3.6.1.2.1.33.1.7.3.0"
}

/// Alimentation de la sortie de l'onduleur.
public enum UPSPowerSource: String, Codable, Sendable, CaseIterable {
    case mains, boost, trim, battery, bypass, off, other, unknown

    public var label: String {
        switch self {
        case .mains: return "Secteur"
        case .boost: return "Secteur (survolteur)"
        case .trim: return "Secteur (dévolteur)"
        case .battery: return "Sur batterie"
        case .bypass: return "Contournement (bypass)"
        case .off: return "Sortie coupée"
        case .other: return "Autre"
        case .unknown: return "Inconnu"
        }
    }

    /// upsOutputSource (RFC 1628) et xupsOutputSource (Eaton, mêmes valeurs).
    static func standard(_ value: Int) -> UPSPowerSource {
        switch value {
        case 2: return .off
        case 3: return .mains
        case 4: return .bypass
        case 5: return .battery
        case 6: return .boost
        case 7: return .trim
        case 1: return .other
        default: return .unknown
        }
    }

    /// upsBasicOutputStatus (APC) ; `cyberPower` : upsBaseOutputStatus, numérotation voisine.
    static func vendor(_ value: Int, cyberPower: Bool) -> UPSPowerSource {
        if cyberPower {
            switch value {
            case 2: return .mains
            case 3: return .battery
            case 4: return .boost
            case 5, 6: return .off
            case 7: return .other
            case 8: return .bypass
            case 12: return .trim
            default: return .unknown
            }
        }
        switch value {
        case 2: return .mains
        case 3: return .battery
        case 4: return .boost
        case 12: return .trim
        case 6, 9, 10: return .bypass
        case 5, 7, 11: return .off
        case 8: return .other
        default: return .unknown
        }
    }
}

/// État de la batterie.
public enum UPSBatteryStatus: String, Codable, Sendable {
    case normal, low, depleted, fault, unknown

    public var label: String {
        switch self {
        case .normal: return "Normale"
        case .low: return "Faible"
        case .depleted: return "Épuisée"
        case .fault: return "En défaut"
        case .unknown: return "Inconnu"
        }
    }
}

/// Résultat du dernier test de la batterie.
public enum UPSTestResult: String, Codable, Sendable {
    case passed, warning, failed, aborted, inProgress, none

    public var label: String {
        switch self {
        case .passed: return "Réussi"
        case .warning: return "Réussi avec avertissement"
        case .failed: return "Échoué"
        case .aborted: return "Interrompu"
        case .inProgress: return "En cours"
        case .none: return "Aucun test"
        }
    }
}

/// Relevé d'un onduleur.
public struct UPSReading: Codable, Hashable, Sendable {
    public var manufacturer: String?
    public var model: String?
    public var source: UPSPowerSource
    public var batteryStatus: UPSBatteryStatus
    /// Charge de la batterie (0 à 100).
    public var chargePercent: Double?
    /// Autonomie restante estimée, en minutes.
    public var runtimeMinutes: Double?
    /// Charge de la sortie, en % de la puissance nominale.
    public var loadPercent: Double?
    public var inputVoltage: Double?
    public var outputVoltage: Double?
    /// Température de la batterie (ou ambiante chez Eaton), en °C.
    public var temperature: Double?
    /// Secondes passées sur batterie (0 sur secteur).
    public var secondsOnBattery: Int?
    public var lastTest: UPSTestResult?
    public var lastTestDate: Date?
    public var batteryReplacedDate: Date?
    /// Voyant « batterie à changer » de l'onduleur.
    public var replaceIndicator: Bool
    /// Alarmes en cours (UPS-MIB), en clair.
    public var alarms: [String]
    /// MIB qui a répondu (« UPS-MIB », « APC PowerNet »…).
    public var mibs: [String]
    public var readAt: Date

    public init(manufacturer: String? = nil, model: String? = nil, source: UPSPowerSource = .unknown,
                batteryStatus: UPSBatteryStatus = .unknown, chargePercent: Double? = nil, runtimeMinutes: Double? = nil,
                loadPercent: Double? = nil, inputVoltage: Double? = nil, outputVoltage: Double? = nil,
                temperature: Double? = nil, secondsOnBattery: Int? = nil, lastTest: UPSTestResult? = nil,
                lastTestDate: Date? = nil, batteryReplacedDate: Date? = nil, replaceIndicator: Bool = false,
                alarms: [String] = [], mibs: [String] = [], readAt: Date = Date()) {
        self.manufacturer = manufacturer
        self.model = model
        self.source = source
        self.batteryStatus = batteryStatus
        self.chargePercent = chargePercent
        self.runtimeMinutes = runtimeMinutes
        self.loadPercent = loadPercent
        self.inputVoltage = inputVoltage
        self.outputVoltage = outputVoltage
        self.temperature = temperature
        self.secondsOnBattery = secondsOnBattery
        self.lastTest = lastTest
        self.lastTestDate = lastTestDate
        self.batteryReplacedDate = batteryReplacedDate
        self.replaceIndicator = replaceIndicator
        self.alarms = alarms
        self.mibs = mibs
        self.readAt = readAt
    }

    public var onBattery: Bool { source == .battery }

    /// Âge de la batterie en années (d'après la date de remplacement publiée).
    public func batteryAgeYears(now: Date) -> Double? {
        batteryReplacedDate.map { max(0, now.timeIntervalSince($0) / (365.25 * 86_400)) }
    }

    /// La batterie est à changer : voyant de l'onduleur, test échoué, batterie en défaut, ou plus
    /// vieille que `UPSMIB.batteryLifeYears`.
    public func batteryDue(now: Date) -> Bool { batteryDueReason(now: now) != nil }

    public func batteryDueReason(now: Date) -> String? {
        if replaceIndicator { return "voyant «\u{00A0}batterie à changer\u{00A0}» allumé" }
        if lastTest == .failed { return "dernier test échoué" }
        if batteryStatus == .fault { return "batterie en défaut" }
        if alarms.contains(UPSMIB.alarmLabel(1)) { return "batterie défectueuse" }
        if let age = batteryAgeYears(now: now), age >= UPSMIB.batteryLifeYears {
            return "batterie posée il y a \(Int(age.rounded(.down)))\u{00A0}ans"
        }
        return nil
    }

    /// « Fabricant Modèle » (« APC Smart-UPS 1500 »).
    public var displayModel: String? {
        let parts = [manufacturer, model].compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !parts.isEmpty else { return nil }
        if let manufacturer, let model, model.lowercased().hasPrefix(manufacturer.lowercased()) { return model }
        return parts.joined(separator: " ")
    }

    /// Résumé d'une ligne (« Secteur · batterie 100 % · autonomie 42 min · charge 31 % »).
    public var summary: String {
        var parts = [source.label]
        if let chargePercent { parts.append("batterie \(UPSMIB.percent(chargePercent))") }
        if let runtimeMinutes { parts.append("autonomie \(UPSMIB.minutes(runtimeMinutes))") }
        if let loadPercent { parts.append("charge \(UPSMIB.percent(loadPercent))") }
        return parts.joined(separator: " · ")
    }
}

public enum UPSMIB {
    /// Autonomie minimale proposée pour la sonde (minutes).
    public static let defaultMinRuntime: Double = 10
    /// Durée de vie usuelle d'une batterie au plomb d'onduleur (années).
    public static let batteryLifeYears: Double = 4

    /// Alarmes connues de la RFC 1628 (upsWellKnownAlarms).
    public static func alarmLabel(_ id: UInt32) -> String {
        switch id {
        case 1: return "Batterie défectueuse"
        case 2: return "Sur batterie"
        case 3: return "Batterie faible"
        case 4: return "Batterie épuisée"
        case 5: return "Température hors limites"
        case 6: return "Entrée hors limites"
        case 7: return "Sortie hors limites"
        case 8: return "Surcharge de la sortie"
        case 9: return "En contournement (bypass)"
        case 10: return "Contournement hors limites"
        case 11: return "Sortie coupée sur demande"
        case 12: return "Onduleur arrêté sur demande"
        case 13: return "Chargeur en panne"
        case 14: return "Sortie coupée"
        case 15: return "Onduleur arrêté"
        case 16: return "Ventilateur en panne"
        case 17: return "Fusible grillé"
        case 18: return "Défaut général"
        case 19: return "Test de diagnostic échoué"
        case 20: return "Communication perdue"
        case 21: return "En attente du secteur"
        case 22: return "Arrêt imminent"
        case 23: return "Arrêt immédiat"
        case 24: return "Test en cours"
        default: return "Alarme \(id)"
        }
    }

    /// Relevé lu dans les varbinds des sous-arbres `UPSMIBOIDs.roots`. Nil si aucune MIB d'onduleur
    /// n'a répondu.
    public static func reading(_ binds: [SNMPVarBind], now: Date = Date()) -> UPSReading? {
        var values: [SNMPOID: SNMPValue] = [:]
        var alarmIDs: [UInt32] = []
        var mibs: [String] = []
        for bind in binds where !bind.value.isException {
            values[bind.oid] = bind.value
            if bind.oid.hasPrefix(UPSMIBOIDs.alarmDescr), case .oid(let alarm) = bind.value,
               let id = alarm.suffix(after: UPSMIBOIDs.wellKnownAlarms)?.first, !alarmIDs.contains(id) {
                alarmIDs.append(id)
            }
            for (root, name) in [(UPSMIBOIDs.standard, "UPS-MIB"), (UPSMIBOIDs.apc, "APC PowerNet"),
                                 (UPSMIBOIDs.eaton, "Eaton XUPS"), (UPSMIBOIDs.cyberPower, "CyberPower")]
            where bind.oid.hasPrefix(root) && !mibs.contains(name) {
                mibs.append(name)
            }
        }
        guard !mibs.isEmpty else { return nil }
        func int(_ oid: SNMPOID) -> Int? { values[oid]?.intValue.map { Int($0) } }
        func double(_ oid: SNMPOID, scale: Double = 1) -> Double? { int(oid).flatMap { $0 >= 0 ? Double($0) * scale : nil } }
        func text(_ oid: SNMPOID) -> String? {
            guard let value = values[oid]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func apc(_ suffix: String) -> SNMPOID { SNMPOID(UPSMIBOIDs.apc.description + "." + suffix)! }
        func eaton(_ suffix: String) -> SNMPOID { SNMPOID(UPSMIBOIDs.eaton.description + "." + suffix)! }
        func cps(_ suffix: String) -> SNMPOID { SNMPOID(UPSMIBOIDs.cyberPower.description + "." + suffix)! }
        func first<T>(_ candidates: T?...) -> T? { candidates.lazy.compactMap { $0 }.first }

        var reading = UPSReading(readAt: now)
        reading.mibs = mibs
        let vendorName: String? = mibs.contains("APC PowerNet") ? "APC" : mibs.contains("Eaton XUPS") ? "Eaton"
            : mibs.contains("CyberPower") ? "CyberPower" : nil
        reading.manufacturer = text(UPSMIBOIDs.manufacturer) ?? vendorName
        reading.model = first(text(UPSMIBOIDs.model), text(apc("1.1.1.0")), text(eaton("1.2.0")), text(cps("1.1.1.0")))

        // Alimentation : la MIB standard, sinon celle du fabricant.
        if let value = int(UPSMIBOIDs.outputSource) {
            reading.source = UPSPowerSource.standard(value)
        } else if let value = int(eaton("4.5.0")) {
            reading.source = UPSPowerSource.standard(value)
        } else if let value = int(apc("4.1.1.0")) {
            reading.source = UPSPowerSource.vendor(value, cyberPower: false)
        } else if let value = int(cps("4.1.1.0")) {
            reading.source = UPSPowerSource.vendor(value, cyberPower: true)
        }

        // État de la batterie : 1 inconnu, 2 normale, 3 faible, 4 épuisée (RFC) ou en défaut (APC).
        if let value = int(UPSMIBOIDs.batteryStatus) {
            reading.batteryStatus = [2: .normal, 3: .low, 4: .depleted][value] ?? .unknown
        } else if let value = first(int(apc("2.1.1.0")), int(cps("2.1.1.0"))) {
            reading.batteryStatus = [2: .normal, 3: .low, 4: .fault][value] ?? .unknown
        } else if let value = int(eaton("2.5.0")) {
            reading.batteryStatus = value == 8 ? .fault : (1...4).contains(value) ? .normal : .unknown
        }

        reading.chargePercent = first(double(UPSMIBOIDs.chargeRemaining), double(apc("2.2.1.0")),
                                      double(eaton("2.4.0")), double(cps("2.2.1.0")))
        // Autonomie : minutes (RFC), TimeTicks en centièmes de seconde (APC, CyberPower), secondes (Eaton).
        reading.runtimeMinutes = first(double(UPSMIBOIDs.minutesRemaining), double(apc("2.2.3.0"), scale: 1 / 6_000),
                                       double(eaton("2.1.0"), scale: 1 / 60), double(cps("2.2.4.0"), scale: 1 / 6_000))
        reading.loadPercent = first(double(UPSMIBOIDs.outputLoad), double(apc("4.2.3.0")),
                                    double(eaton("4.1.0")), double(cps("4.2.3.0")))
        // Tensions : volts (RFC, APC, Eaton), dixièmes de volt (CyberPower).
        reading.inputVoltage = first(double(UPSMIBOIDs.inputVoltage), double(apc("3.2.1.0")),
                                     double(eaton("3.4.1.2.1")), double(cps("3.2.1.0"), scale: 0.1))
        reading.outputVoltage = first(double(UPSMIBOIDs.outputVoltage), double(apc("4.2.1.0")),
                                      double(eaton("4.4.1.2.1")), double(cps("4.2.1.0"), scale: 0.1))
        reading.temperature = first(double(UPSMIBOIDs.batteryTemperature), double(apc("2.2.2.0")),
                                    double(cps("2.2.3.0")), double(eaton("6.1.0")))
        reading.secondsOnBattery = first(int(UPSMIBOIDs.secondsOnBattery), int(apc("2.1.2.0")).map { $0 / 100 })

        if let value = int(UPSMIBOIDs.testResult) {
            reading.lastTest = [1: .passed, 2: .warning, 3: .failed, 4: .aborted, 5: .inProgress, 6: UPSTestResult.none][value]
        } else if let value = first(int(apc("7.2.3.0")), int(cps("7.2.3.0"))) {
            reading.lastTest = [1: .passed, 2: .failed, 4: .inProgress][value]
        } else if let value = int(eaton("8.2.0")) {
            reading.lastTest = [2: .passed, 3: .failed, 4: .inProgress][value]
        }
        reading.lastTestDate = first(text(apc("7.2.4.0")), text(cps("7.2.4.0"))).flatMap(parseDate)
        reading.batteryReplacedDate = first(text(apc("2.1.3.0")), text(eaton("2.6.0")), text(cps("2.1.3.0"))).flatMap(parseDate)
        reading.replaceIndicator = first(int(apc("2.2.4.0")), int(cps("2.2.5.0"))) == 2
        reading.alarms = alarmIDs.map(alarmLabel)
        return reading
    }

    /// Date des MIB des fabricants : « 03/14/22 », « 03/14/2022 » (mois d'abord) ou « 2022-03-14 ».
    /// Rendue à midi UTC, pour s'afficher le même jour partout.
    public static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var year = 0, month = 0, day = 0
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            (year, month, day) = (parts[0], parts[1], parts[2])
        } else {
            let parts = trimmed.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            (month, day, year) = (parts[0], parts[1], parts[2])
            if year < 100 { year += 2000 }
        }
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// « 12 mars 2024 » (date rendue par `parseDate`).
    public static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// « 42 min », « 1 h 05 ».
    public static func minutes(_ value: Double) -> String {
        let total = Int(value.rounded())
        guard total >= 60 else { return "\(total)\u{00A0}min" }
        return String(format: "%d\u{00A0}h\u{00A0}%02d", total / 60, total % 60)
    }

    /// « 31 % ».
    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))\u{00A0}%" }

    /// Lit le relevé avec une requête fournie (client UDP, agent en mémoire). Lève une erreur si
    /// aucune MIB d'onduleur ne répond.
    public static func read(now: Date = Date(), fetch: (SNMPPDU) async throws -> SNMPPDU) async throws -> UPSReading {
        var binds: [SNMPVarBind] = []
        for root in UPSMIBOIDs.roots {
            let result = try await SNMPWalker.walk(root, mode: .bulk(maxRepetitions: 20), limit: 300, fetch: fetch)
            binds += result.binds
        }
        guard let reading = reading(binds, now: now) else { throw UPSMIBError.noUPS }
        return reading
    }

    /// Lecture par un client SNMP (v2c, ou v3 avec le client v3 sous-jacent).
    public static func read(client: SNMPClient, now: Date = Date()) async throws -> UPSReading {
        try await read(now: now) { pdu in try await client.request(pdu, checkStatus: false) }
    }
}

public enum UPSMIBError: Error, LocalizedError, Equatable {
    case noUPS

    public var errorDescription: String? {
        switch self {
        case .noUPS: return "Aucune MIB d’onduleur publiée par SNMP (UPS-MIB, APC, Eaton ou CyberPower absente\u{00A0}: carte réseau sans SNMP, ou pas un onduleur)."
        }
    }
}
