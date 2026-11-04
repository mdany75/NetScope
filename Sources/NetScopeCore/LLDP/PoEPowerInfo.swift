import Foundation

/// Alimentation par Ethernet (PoE) annoncée par le switch voisin : TLV 802.3 « Power via MDI »
/// (avec les champs étendus 802.3at et 802.3bt), LLDP-MED « Extended Power-via-MDI » et TLV PoE
/// de CDP. Répond à « Suis-je sur un port PoE, et ce port fournit-il du courant ? ».
///
/// Un Mac ne consomme pas de PoE : pour lui, la réponse dit seulement si le port de la switch est
/// PoE et s'il fournit du courant.
public struct PoEPowerInfo: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case lldp8023 = "LLDP 802.3"
        case lldpMED = "LLDP-MED"
        case cdp = "CDP"
    }

    /// Rôle du port qui annonce : source de courant (PSE, le switch) ou appareil alimenté (PD).
    public enum Role: String, Codable, Sendable {
        case pse, pd

        public var label: String { self == .pse ? "PSE (source, switch)" : "PD (appareil alimenté)" }
    }

    public enum Standard: String, Codable, Sendable {
        case af = "802.3af"
        case at = "802.3at"
        case bt = "802.3bt"
    }

    public enum Priority: String, Codable, Sendable {
        case critical, high, low

        public var label: String {
            switch self {
            case .critical: return "critique"
            case .high: return "haute"
            case .low: return "basse"
            }
        }
    }

    /// TLV reçus (dans l'ordre).
    public var sources: [Source]
    public var role: Role?
    /// PoE pris en charge par le port annonceur (bit « supported » de 802.3).
    public var supported: Bool?
    /// PoE activé sur le port (bit « enabled » de 802.3).
    public var enabled: Bool?
    /// Choix des paires possible (bit « pairs control »).
    public var pairsControllable: Bool?
    /// Paires utilisées : 1 = signal (alternative A), 2 = libres (alternative B).
    public var powerPairs: Int?
    /// Classe de puissance : 0 à 4 (802.3af/at), 1 à 8 (802.3bt).
    public var powerClass: Int?
    public var standard: Standard?
    /// Type 1 à 4 (802.3at : 1 ou 2 ; 802.3bt : 3 ou 4).
    public var powerType: Int?
    /// Source d'alimentation annoncée (« principale », « secours », « PSE et locale »…).
    public var powerSource: String?
    public var priority: Priority?
    /// Puissance demandée par l'appareil alimenté (W).
    public var requestedW: Double?
    /// Puissance allouée par le switch (W).
    public var allocatedW: Double?
    /// Puissance disponible sur le port (LLDP-MED côté PSE, CDP « Power Available »), en W.
    public var availableW: Double?
    /// Puissance maximale que le PSE peut fournir (802.3bt), en W.
    public var pseMaxAvailableW: Double?
    /// État d'alimentation 802.3bt : « 2 paires », « 4 paires (signature simple) »…
    public var poweringStatus: String?
    /// CDP « Power » (0x0010) : consommation déclarée par l'équipement voisin lui-même, en W.
    public var deviceConsumptionW: Double?

    public init(sources: [Source] = [], role: Role? = nil, supported: Bool? = nil, enabled: Bool? = nil,
                pairsControllable: Bool? = nil, powerPairs: Int? = nil, powerClass: Int? = nil, standard: Standard? = nil,
                powerType: Int? = nil, powerSource: String? = nil, priority: Priority? = nil, requestedW: Double? = nil,
                allocatedW: Double? = nil, availableW: Double? = nil, pseMaxAvailableW: Double? = nil,
                poweringStatus: String? = nil, deviceConsumptionW: Double? = nil) {
        self.sources = sources
        self.role = role
        self.supported = supported
        self.enabled = enabled
        self.pairsControllable = pairsControllable
        self.powerPairs = powerPairs
        self.powerClass = powerClass
        self.standard = standard
        self.powerType = powerType
        self.powerSource = powerSource
        self.priority = priority
        self.requestedW = requestedW
        self.allocatedW = allocatedW
        self.availableW = availableW
        self.pseMaxAvailableW = pseMaxAvailableW
        self.poweringStatus = poweringStatus
        self.deviceConsumptionW = deviceConsumptionW
    }

    // MARK: Réponses

    /// Le port du switch est-il un port PoE ? nil si l'annonce ne permet pas de le dire.
    public var isPoEPort: Bool? {
        if sources.contains(.lldp8023) {
            if role == .pd { return false }
            if supported == true || role == .pse { return supported != false }
            return false
        }
        if sources.contains(.lldpMED) { return role == .pse ? true : (role == .pd ? false : nil) }
        if availableW != nil { return true }
        return nil
    }

    /// Le port fournit-il du courant en ce moment ? nil si l'annonce ne le dit pas.
    public var isPowerDelivered: Bool? {
        if isPoEPort == false { return false }
        if enabled == false { return false }
        if poweringStatus != nil { return true }
        if let allocatedW { return allocatedW > 0 }
        return nil
    }

    /// « 802.3at (Type 2) », « 802.3bt (Type 3) », « 802.3af ».
    public var typeLabel: String? {
        guard let standard else { return nil }
        return powerType.map { "\(standard.rawValue) (Type \($0))" } ?? standard.rawValue
    }

    /// « Classe 4 »
    public var classLabel: String? { powerClass.map { "Classe \($0)" } }

    /// Résumé d'une ligne (« 802.3at · 15,4 W alloués », « 802.3at · non utilisé », « CDP · 15 W »).
    public var summary: String {
        if sources.contains(.lldp8023) {
            guard isPoEPort == true else { return "Pas de PoE" }
            let standard = self.standard?.rawValue ?? Standard.af.rawValue
            if enabled == false { return "\(standard) · désactivé" }
            if let allocatedW {
                return allocatedW > 0 ? "\(standard) · \(Self.watts(allocatedW)) alloués" : "\(standard) · non utilisé"
            }
            return powerClass.map { "\(standard) · classe \($0)" } ?? standard
        }
        if sources.contains(.lldpMED), let availableW { return "LLDP-MED · \(Self.watts(availableW))" }
        if sources.contains(.lldpMED), let requestedW { return "LLDP-MED · \(Self.watts(requestedW)) demandés" }
        if let availableW { return "CDP · \(Self.watts(availableW)) disponibles" }
        if let deviceConsumptionW { return "CDP · \(Self.watts(deviceConsumptionW))" }
        return "PoE annoncé"
    }

    /// « Oui », « Non » ou « Non annoncé ».
    public static func answer(_ value: Bool?) -> String {
        switch value {
        case true?: return "Oui"
        case false?: return "Non"
        case nil: return "Non annoncé"
        }
    }

    /// « 15,4 W » (espace insécable).
    public static func watts(_ watts: Double) -> String { LLDPDecoder.wattsText(watts) }

    /// « 15,4 W demandés · 15,4 W alloués »
    public var powerLabel: String? {
        var parts: [String] = []
        if let requestedW, requestedW > 0 { parts.append("\(Self.watts(requestedW)) demandés") }
        if let allocatedW { parts.append("\(Self.watts(allocatedW)) alloués") }
        if allocatedW == nil, let availableW { parts.append("\(Self.watts(availableW)) disponibles") }
        if let pseMaxAvailableW, pseMaxAvailableW > 0 { parts.append("max \(Self.watts(pseMaxAvailableW))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Fusionne deux annonces (LLDP et CDP du même switch) : les valeurs de `self` l'emportent.
    public func merged(with other: PoEPowerInfo) -> PoEPowerInfo {
        var result = self
        for source in other.sources where !result.sources.contains(source) { result.sources.append(source) }
        result.role = role ?? other.role
        result.supported = supported ?? other.supported
        result.enabled = enabled ?? other.enabled
        result.pairsControllable = pairsControllable ?? other.pairsControllable
        result.powerPairs = powerPairs ?? other.powerPairs
        result.powerClass = powerClass ?? other.powerClass
        result.standard = standard ?? other.standard
        result.powerType = powerType ?? other.powerType
        result.powerSource = powerSource ?? other.powerSource
        result.priority = priority ?? other.priority
        result.requestedW = requestedW ?? other.requestedW
        result.allocatedW = allocatedW ?? other.allocatedW
        result.availableW = availableW ?? other.availableW
        result.pseMaxAvailableW = pseMaxAvailableW ?? other.pseMaxAvailableW
        result.poweringStatus = poweringStatus ?? other.poweringStatus
        result.deviceConsumptionW = deviceConsumptionW ?? other.deviceConsumptionW
        return result
    }
}

// MARK: - Décodage

public enum PoEDecoder {
    /// TLV 802.3 Power via MDI (OUI 00-12-0F, sous-type 2), charge après l'OUI et le sous-type.
    ///
    /// - 3 octets : prise en charge (bits : PSE, pris en charge, activé, choix des paires), paires, classe ;
    /// - 802.3at (+5) : type/source/priorité, puissance demandée et allouée (0,1 W) ;
    /// - 802.3bt (+17) : demandée et allouée par mode A et B, état d'alimentation, type étendu,
    ///   puissance maximale du PSE, autoclass, mise hors tension.
    public static func powerViaMDI(_ info: [UInt8]) -> PoEPowerInfo? {
        guard info.count >= 3 else { return nil }
        var poe = PoEPowerInfo(sources: [.lldp8023])
        let support = info[0]
        poe.role = support & 0x01 != 0 ? .pse : .pd
        poe.supported = support & 0x02 != 0
        poe.enabled = support & 0x04 != 0
        poe.pairsControllable = support & 0x08 != 0
        if (1...2).contains(info[1]) { poe.powerPairs = Int(info[1]) }
        if (1...5).contains(info[2]) { poe.powerClass = Int(info[2]) - 1 }
        poe.standard = .af
        if info.count >= 8 {
            let flags = info[3]
            // Bits 7-6 : 00 Type 2 PSE, 01 Type 2 PD, 10 Type 1 PSE, 11 Type 1 PD.
            let type1 = flags & 0x80 != 0
            poe.powerType = type1 ? 1 : 2
            poe.standard = type1 ? .af : .at
            let isPD = flags & 0x40 != 0
            poe.powerSource = source(Int((flags >> 4) & 0x03), isPD: isPD)
            poe.priority = priority(Int(flags & 0x03))
            poe.requestedW = Double(CaptureBytes.u16(info, 4)) / 10
            poe.allocatedW = Double(CaptureBytes.u16(info, 6)) / 10
        }
        if info.count >= 25 {
            let requestedA = Double(CaptureBytes.u16(info, 8)) / 10
            let requestedB = Double(CaptureBytes.u16(info, 10)) / 10
            let allocatedA = Double(CaptureBytes.u16(info, 12)) / 10
            let allocatedB = Double(CaptureBytes.u16(info, 14)) / 10
            // Signature double : les totaux sont répartis entre les modes A et B.
            if poe.requestedW == 0, requestedA + requestedB > 0 { poe.requestedW = requestedA + requestedB }
            if poe.allocatedW == 0, allocatedA + allocatedB > 0 { poe.allocatedW = allocatedA + allocatedB }
            let status = CaptureBytes.u16(info, 16)
            switch status >> 14 {
            case 1: poe.poweringStatus = "2 paires"
            case 2: poe.poweringStatus = "4 paires (signature simple)"
            case 3: poe.poweringStatus = "4 paires (signature double)"
            default: break
            }
            let classExt = Int(status & 0x0F)
            if (1...8).contains(classExt) { poe.powerClass = classExt }
            // Type étendu (bits 3-1) : 2 Type 3 PSE, 3 Type 4 PSE, 4-5 Type 3 PD, 6-7 Type 4 PD.
            let typeExt = Int((info[18] >> 1) & 0x07)
            switch typeExt {
            case 2, 4, 5: poe.powerType = 3; poe.standard = .bt
            case 3, 6, 7: poe.powerType = 4; poe.standard = .bt
            default: break
            }
            let maxAvailable = Double(CaptureBytes.u16(info, 19)) / 10
            if maxAvailable > 0 { poe.pseMaxAvailableW = maxAvailable }
        }
        return poe
    }

    /// LLDP-MED Extended Power-via-MDI (OUI 00-12-BB, sous-type 4) : type (PSE/PD), source,
    /// priorité, puissance (0,1 W) : disponible côté switch, demandée côté appareil.
    public static func medExtendedPower(_ info: [UInt8]) -> PoEPowerInfo? {
        guard info.count >= 3 else { return nil }
        var poe = PoEPowerInfo(sources: [.lldpMED])
        let flags = info[0]
        let type = Int(flags >> 6)
        guard type <= 1 else { return nil }
        poe.role = type == 0 ? .pse : .pd
        poe.powerSource = source(Int((flags >> 4) & 0x03), isPD: type == 1)
        switch flags & 0x0F {
        case 1: poe.priority = .critical
        case 2: poe.priority = .high
        case 3: poe.priority = .low
        default: break
        }
        let watts = Double(CaptureBytes.u16(info, 1)) / 10
        if type == 0 { poe.availableW = watts } else { poe.requestedW = watts }
        return poe
    }

    /// CDP « Power » (0x0010) : consommation de l'équipement voisin, en mW sur 2 octets.
    public static func cdpPower(_ value: [UInt8]) -> PoEPowerInfo? {
        guard value.count >= 2 else { return nil }
        return PoEPowerInfo(sources: [.cdp], deviceConsumptionW: Double(CaptureBytes.u16(value, 0)) / 1000)
    }

    /// CDP « Power Available » (0x001A) : identifiants de demande et de gestion (2 + 2), puissance
    /// disponible (4, mW), niveau de gestion (4). Envoyé par un switch sur un port PoE.
    public static func cdpPowerAvailable(_ value: [UInt8]) -> PoEPowerInfo? {
        guard value.count >= 8 else { return nil }
        let available = Double(CaptureBytes.u32(value, 4)) / 1000
        return PoEPowerInfo(sources: [.cdp], role: .pse, availableW: available)
    }

    /// CDP « Power Requested » (0x0019) : identifiants (2 + 2) puis puissances demandées (4, mW).
    public static func cdpPowerRequested(_ value: [UInt8]) -> PoEPowerInfo? {
        guard value.count >= 8 else { return nil }
        let requested = Double(CaptureBytes.u32(value, 4)) / 1000
        return PoEPowerInfo(sources: [.cdp], role: .pd, requestedW: requested)
    }

    static func source(_ bits: Int, isPD: Bool) -> String? {
        switch (bits, isPD) {
        case (1, false): return "Principale"
        case (2, false): return "Secours"
        case (1, true): return "PSE"
        case (2, true): return "Locale"
        case (3, true): return "PSE et locale"
        default: return nil
        }
    }

    /// 802.3at : 01 critique, 10 haute, 11 basse.
    static func priority(_ bits: Int) -> PoEPowerInfo.Priority? {
        switch bits {
        case 1: return .critical
        case 2: return .high
        case 3: return .low
        default: return nil
        }
    }
}
