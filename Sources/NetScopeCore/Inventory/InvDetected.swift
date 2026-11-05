import Foundation

// Note 60 : fiche matériel remplie automatiquement. Modèle, numéro de série et version du logiciel
// lus par SNMP (ENTITY-MIB, sysDescr) ou par la FortiGate (FortiGate, FortiSwitch, FortiAP), gardés
// À PART des champs saisis (InvRecord.detectedHardware) : rien de ce que le technicien a écrit n'est
// écrasé. Le numéro saisi n'est rempli que par « Reprendre » (adoptDetectedSerial).
//
// Rapprochement des lectures de la FortiGate (InvHardwareMatcher) : numéro de série, MAC, nom, puis
// IP seulement si la fiche est elle aussi un appareil Fortinet ; toujours DANS l'inventaire du site de
// la FortiGate (un site n'a que ses propres données). Rien ici n'accède au réseau.

/// D'où vient la fiche matériel détectée.
public enum InvHardwareSource: String, Codable, Sendable, CaseIterable {
    case snmp, fortigate

    public var label: String {
        switch self {
        case .snmp: return "SNMP"
        case .fortigate: return "FortiGate"
        }
    }
}

/// Modèle, numéro de série et firmware lus sur l'appareil (jamais saisis).
public struct InvDetectedHardware: Codable, Hashable, Sendable {
    public var model: String?
    public var serialNumber: String?
    public var firmware: String?
    public var vendor: String?
    public var source: InvHardwareSource
    /// Précision de la source : « ENTITY-MIB », « sysDescr », nom de la FortiGate.
    public var detail: String?
    public var readAt: Date

    public init(model: String? = nil, serialNumber: String? = nil, firmware: String? = nil, vendor: String? = nil,
                source: InvHardwareSource, detail: String? = nil, readAt: Date) {
        self.model = Self.clean(model)
        self.serialNumber = Self.clean(serialNumber)
        self.firmware = Self.clean(firmware)
        self.vendor = Self.clean(vendor)
        self.source = source
        self.detail = Self.clean(detail)
        self.readAt = readAt
    }

    /// Lecture SNMP (relevé d'un switch, Ressources, bouton « Lire la fiche matériel »).
    public init(snmp info: SNMPHardwareInfo, readAt: Date) {
        self.init(model: info.model, serialNumber: info.serial, firmware: info.firmware, vendor: info.vendor,
                  source: .snmp, detail: info.origin, readAt: readAt)
    }

    public var isEmpty: Bool { model == nil && serialNumber == nil && firmware == nil }

    /// « SNMP · ENTITY-MIB », « FortiGate · FG-SIEGE ».
    public var sourceLabel: String { [source.label, detail].compactMap { $0 }.joined(separator: " · ") }

    /// Mêmes valeurs lues (la date de lecture mise à part).
    public func sameValues(as other: InvDetectedHardware) -> Bool {
        model == other.model && serialNumber == other.serialNumber && firmware == other.firmware && vendor == other.vendor
            && source == other.source && detail == other.detail
    }

    /// Fiabilité de la lecture : sysDescr seul (1) est moins précis qu'ENTITY-MIB ou la FortiGate (2).
    public var strength: Int {
        source == .snmp && detail == "sysDescr" ? 1 : 2
    }

    /// Cette lecture posée sur la précédente : ce qu'elle ne dit pas est gardé, sauf si le numéro de
    /// série a changé (appareil remplacé à la même place : l'ancienne fiche ne vaut plus rien). Une
    /// lecture moins fiable (sysDescr à la fin d'un scan) ne fait que compléter une lecture plus
    /// fiable (ENTITY-MIB, FortiGate) : « Catalyst 9000 » ne remplace pas « C9300-48P ».
    public func merged(over previous: InvDetectedHardware?) -> InvDetectedHardware {
        guard let previous else { return self }
        if let new = serialNumber, let old = previous.serialNumber,
           Self.normalizedSerial(new) != Self.normalizedSerial(old) { return self }
        if strength < previous.strength {
            var kept = previous
            if kept.model == nil { kept.model = model }
            if kept.serialNumber == nil { kept.serialNumber = serialNumber }
            if kept.firmware == nil { kept.firmware = firmware }
            if kept.vendor == nil { kept.vendor = vendor }
            return kept
        }
        var result = self
        if result.model == nil { result.model = previous.model }
        if result.serialNumber == nil { result.serialNumber = previous.serialNumber }
        if result.firmware == nil { result.firmware = previous.firmware }
        if result.vendor == nil { result.vendor = previous.vendor }
        return result
    }

    /// Numéro de série comparable : majuscules, sans espace ni tiret.
    public static func normalizedSerial(_ text: String) -> String {
        String(text.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    static func clean(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Numéro de série saisi comparé au détecté.
public enum InvSerialCheck: Hashable, Sendable {
    /// Aucun numéro détecté.
    case nothingDetected
    /// Rien de saisi : le détecté peut être repris.
    case canAdopt(String)
    case same
    /// Saisi et détecté diffèrent.
    case differs(entered: String, detected: String)
}

extension InvRecord {
    /// Numéro de série saisi par le technicien (fiche matériel), rogné.
    public var enteredSerial: String {
        annotations.hardware?.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public var serialCheck: InvSerialCheck {
        guard let detected = detectedHardware?.serialNumber else { return .nothingDetected }
        let entered = enteredSerial
        if entered.isEmpty { return .canAdopt(detected) }
        return InvDetectedHardware.normalizedSerial(entered) == InvDetectedHardware.normalizedSerial(detected)
            ? .same : .differs(entered: entered, detected: detected)
    }

    /// Modèle détecté (« » s'il n'y en a pas) : colonne et export.
    public var detectedModelLabel: String { detectedHardware?.model ?? "" }
    /// Firmware détecté (« » s'il n'y en a pas) : colonne et export.
    public var detectedFirmwareLabel: String { detectedHardware?.firmware ?? "" }
}

// MARK: - Rapprochement

/// Fiche matériel lue sur un équipement, à rattacher à une fiche de l'inventaire.
public struct InvHardwareCandidate: Hashable, Sendable {
    /// Nom de l'équipement (nom d'hôte de la FortiGate, nom du FortiSwitch ou de la FortiAP, sysName).
    public var name: String
    public var ip: IPv4Address?
    public var mac: MACAddress?
    /// Rapprochement par la seule IP : seulement si le fabricant de la fiche contient ce texte
    /// (« Fortinet ») ; nil : l'IP suffit (lecture SNMP faite à l'instant sur cette adresse).
    public var ipVendorHint: String?
    public var hardware: InvDetectedHardware

    public init(name: String, ip: IPv4Address? = nil, mac: MACAddress? = nil, ipVendorHint: String? = nil,
                hardware: InvDetectedHardware) {
        self.name = name
        self.ip = ip
        self.mac = mac
        self.ipVendorHint = ipVendorHint
        self.hardware = hardware
    }
}

/// Une fiche rapprochée et la façon dont elle l'a été.
public struct InvHardwareMatch: Hashable, Sendable {
    public enum Reason: String, Sendable {
        case serial, mac, name, ip
    }

    public var key: String
    public var reason: Reason
    public var hardware: InvDetectedHardware
}

public enum InvHardwareMatcher {
    /// « FSW-QUAI.local » → « fsw-quai ».
    public static func normalizedName(_ text: String) -> String {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(lower.split(separator: ".").first ?? Substring(lower))
    }

    /// Rapproche chaque candidat d'une seule fiche, quand c'est sûr : numéro de série saisi ou déjà
    /// détecté, MAC, nom (unique, et sans IP contradictoire), puis IP (une seule fiche en ligne, et du
    /// bon fabricant si `ipVendorHint`). Une fiche ne reçoit qu'un candidat. Les fiches données
    /// doivent être celles d'UN site : l'appelant ne mélange jamais les sites.
    public static func match(_ candidates: [InvHardwareCandidate], in records: [InvRecord]) -> [InvHardwareMatch] {
        var used = Set<String>()
        var result: [InvHardwareMatch] = []
        let available = { (list: [InvRecord]) in list.filter { !used.contains($0.key) } }
        for candidate in candidates where !candidate.hardware.isEmpty {
            let pool = available(records)
            var found: (InvRecord, InvHardwareMatch.Reason)?
            if let serial = candidate.hardware.serialNumber.map(InvDetectedHardware.normalizedSerial), !serial.isEmpty {
                let hits = pool.filter { record in
                    let entered = InvDetectedHardware.normalizedSerial(record.enteredSerial)
                    let detected = record.detectedHardware?.serialNumber.map(InvDetectedHardware.normalizedSerial) ?? ""
                    return entered == serial || detected == serial
                }
                if hits.count == 1 { found = (hits[0], .serial) }
            }
            if found == nil, let mac = candidate.mac {
                let hits = pool.filter { $0.mac == mac }
                if hits.count == 1 { found = (hits[0], .mac) }
            }
            if found == nil {
                let name = normalizedName(candidate.name)
                if !name.isEmpty {
                    let hits = pool.filter { record in
                        [record.hostname, record.annotations.customName].compactMap { $0 }.map(normalizedName).contains(name)
                    }
                    if hits.count == 1 {
                        let record = hits[0]
                        let contradicts = candidate.ip.map { ip in record.hasAddress && record.ip != ip } ?? false
                        if !contradicts { found = (record, .name) }
                    }
                }
            }
            if found == nil, let ip = candidate.ip {
                let sameIP = pool.filter { $0.hasAddress && $0.ip == ip }
                let online = sameIP.filter(\.isOnline)
                let hits = online.isEmpty ? sameIP : online
                if hits.count == 1 {
                    let record = hits[0]
                    let vendorOK = candidate.ipVendorHint.map { hint in
                        record.vendorLabel.lowercased().contains(hint.lowercased())
                    } ?? true
                    if vendorOK { found = (record, .ip) }
                }
            }
            guard let (record, reason) = found else { continue }
            used.insert(record.key)
            result.append(InvHardwareMatch(key: record.key, reason: reason, hardware: candidate.hardware))
        }
        return result
    }

    /// Équipements d'une lecture de la FortiGate (inventaire firmware : FortiGate, FortiSwitch,
    /// FortiAP), prêts à rapprocher. `fortigateIP` : adresse de la FortiGate (sa propre fiche) ;
    /// les FortiSwitch n'ont pas d'IP ici (leur adresse FortiLink n'est pas celle du scan).
    public static func candidates(from site: FirmwareSiteReport, fortigateIP: IPv4Address?) -> [InvHardwareCandidate] {
        let report = site.report
        let readAt = report.readAt
        var result: [InvHardwareCandidate] = []
        let controllerName = report.system.map { $0.hostname.isEmpty ? site.site : $0.hostname } ?? site.site
        for device in FirmwareAnalysis.devices(site) {
            let firmware = device.version?.description ?? (device.versionText.isEmpty ? nil : device.versionText)
            let hardware = InvDetectedHardware(model: device.model, serialNumber: device.serial, firmware: firmware,
                                               vendor: "Fortinet", source: .fortigate,
                                               detail: device.kind == .fortigate ? device.name : controllerName, readAt: readAt)
            var ip: IPv4Address?
            switch device.kind {
            case .fortigate: ip = fortigateIP
            case .fortiap: ip = report.accessPoints.first { $0.serial == device.serial && !device.serial.isEmpty }?.ip
            case .fortiswitch: ip = nil
            }
            result.append(InvHardwareCandidate(name: device.name, ip: ip, ipVendorHint: "Fortinet", hardware: hardware))
        }
        return result
    }
}

// MARK: - Inventaire

extension InventoryStore {
    /// Pose une fiche matériel détectée sur une fiche (fusionnée avec la précédente). Renvoie vrai si
    /// une valeur a changé (une simple relecture identique ne met à jour que la date).
    @discardableResult
    public mutating func setDetectedHardware(_ hardware: InvDetectedHardware, for key: String) -> Bool {
        guard var record = records[key], !hardware.isEmpty else { return false }
        let merged = hardware.merged(over: record.detectedHardware)
        let changed = record.detectedHardware.map { !$0.sameValues(as: merged) } ?? true
        guard changed || record.detectedHardware?.readAt != merged.readAt else { return false }
        record.detectedHardware = merged
        records[key] = record
        return changed
    }

    /// Rapproche et pose des lectures (FortiGate) ; renvoie les rapprochements faits.
    @discardableResult
    public mutating func applyDetected(_ candidates: [InvHardwareCandidate]) -> [InvHardwareMatch] {
        let matches = InvHardwareMatcher.match(candidates, in: sortedRecords)
        for match in matches { setDetectedHardware(match.hardware, for: match.key) }
        return matches
    }

    /// Lecture SNMP faite sur une adresse de ce site : fiche de cette IP (en ligne d'abord), sinon du
    /// même nom (sysName). Renvoie la clé de la fiche mise à jour.
    @discardableResult
    public mutating func applySNMPHardware(_ info: SNMPHardwareInfo, host: IPv4Address, sysName: String = "",
                                           at date: Date = Date()) -> String? {
        let candidate = InvHardwareCandidate(name: sysName, ip: host, hardware: InvDetectedHardware(snmp: info, readAt: date))
        guard let match = InvHardwareMatcher.match([candidate], in: sortedRecords).first else { return nil }
        setDetectedHardware(match.hardware, for: match.key)
        return match.key
    }

    /// « Reprendre » : le numéro de série détecté devient le numéro saisi, s'il est encore vide.
    @discardableResult
    public mutating func adoptDetectedSerial(for key: String, at date: Date = Date()) -> Bool {
        guard let record = records[key], case .canAdopt(let serial) = record.serialCheck else { return false }
        var annotations = record.annotations
        var hardware = annotations.hardware ?? InvHardware()
        hardware.serialNumber = serial
        annotations.hardware = hardware
        setAnnotations(annotations, for: key, at: date)
        return true
    }
}
