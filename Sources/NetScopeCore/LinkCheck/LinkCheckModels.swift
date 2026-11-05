import Foundation

// Note 58 : bilan de raccordement en un clic, à la manière d'un testeur NetAlly (LinkSprinter,
// LinkRunner). Un seul bouton enchaîne, sur le lien actif : lien (vitesse, duplex), port de switch
// par LLDP/CDP, VLAN, PoE annoncé, DHCP, passerelle, DNS et Internet. Chaque étape reçoit un état
// (OK, avertissement, échec, non vérifié) et une explication en clair. Les bilans sont gardés par
// site, comparés (« avant/après ») et repris dans le rapport.
//
// Ce fichier : le modèle (étapes, constats, résultat). Les mesures et leurs verdicts sont dans
// LinkCheckEvaluator.swift, l'enchaînement dans LinkCheckRunner.swift.

/// État d'une étape du bilan.
public enum LinkCheckStatus: String, Codable, Sendable, CaseIterable, Comparable {
    case ok, warning, failure
    /// Étape qui n'a pas pu être mesurée (Wi-Fi sans switch, droits manquants, pas d'adresse…).
    case skipped

    /// Gravité : non vérifié < OK < avertissement < échec.
    public var rank: Int {
        switch self {
        case .skipped: return 0
        case .ok: return 1
        case .warning: return 2
        case .failure: return 3
        }
    }

    public static func < (lhs: LinkCheckStatus, rhs: LinkCheckStatus) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Avertissement"
        case .failure: return "Échec"
        case .skipped: return "Non vérifié"
        }
    }
}

/// Étapes du bilan, dans l'ordre affiché (et dans celui du rapport).
public enum LinkCheckStepKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case lien, switchPort = "switch", vlan, poe, dhcp, passerelle, dns, internet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lien: return "Lien"
        case .switchPort: return "Port de switch"
        case .vlan: return "VLAN"
        case .poe: return "PoE annoncé"
        case .dhcp: return "DHCP"
        case .passerelle: return "Passerelle"
        case .dns: return "DNS"
        case .internet: return "Internet"
        }
    }

    /// Ce que l'étape vérifie (infobulle, rapport).
    public var purpose: String {
        switch self {
        case .lien: return "Interface, vitesse négociée et duplex."
        case .switchPort: return "Switch et port annoncés par LLDP ou CDP."
        case .vlan: return "VLAN natif (et VLAN voix) annoncés par le switch."
        case .poe: return "Alimentation PoE annoncée par le port du switch."
        case .dhcp: return "Serveurs DHCP qui répondent, temps d’obtention et options."
        case .passerelle: return "Ping de la passerelle\u{00A0}: perte et latence."
        case .dns: return "Résolution de quelques noms par le serveur DNS du réseau."
        case .internet: return "Requête HTTP vers une adresse neutre."
        }
    }
}

/// Un constat mesuré (« Vitesse : 1 Gb/s »), comparé d'un bilan à l'autre par sa clé.
public struct LinkCheckFact: Codable, Hashable, Sendable {
    /// Clé stable dans l'étape (« vitesse », « perte »…).
    public var key: String
    public var label: String
    public var value: String
    /// Valeur chiffrée pour la comparaison (nil : comparaison du texte).
    public var number: Double?
    /// Sens d'une amélioration : vrai si plus grand vaut mieux, faux si plus petit vaut mieux,
    /// nil si l'écart est seulement un changement (un autre port, un autre serveur).
    public var higherIsBetter: Bool?
    /// Écart absolu en dessous duquel deux valeurs sont jugées identiques (bruit de mesure).
    public var tolerance: Double?

    /// Détail (« nom.microsoft.com ») : l'adresse d'un nom change souvent (CDN), la comparaison
    /// porte sur le nombre de noms résolus et le temps moyen.
    public var isDetail: Bool { key.hasPrefix("nom.") }

    public init(_ key: String, _ label: String, _ value: String, number: Double? = nil, higherIsBetter: Bool? = nil,
                tolerance: Double? = nil) {
        self.key = key
        self.label = label
        self.value = value
        self.number = number
        self.higherIsBetter = higherIsBetter
        self.tolerance = tolerance
    }
}

/// Résultat d'une étape.
public struct LinkCheckStep: Codable, Hashable, Sendable, Identifiable {
    public var kind: LinkCheckStepKind
    public var status: LinkCheckStatus
    /// Résultat en quelques mots (« 1 Gb/s · duplex intégral »).
    public var summary: String
    /// Explication en clair : ce qui a été vu et ce qu'il faut faire.
    public var explanation: String
    public var facts: [LinkCheckFact]
    /// Durée de la mesure, en secondes.
    public var seconds: Double?

    public var id: String { kind.rawValue }

    public init(kind: LinkCheckStepKind, status: LinkCheckStatus, summary: String, explanation: String,
                facts: [LinkCheckFact] = [], seconds: Double? = nil) {
        self.kind = kind
        self.status = status
        self.summary = summary
        self.explanation = explanation
        self.facts = facts
        self.seconds = seconds
    }

    public func fact(_ key: String) -> LinkCheckFact? { facts.first { $0.key == key } }

    /// Constats de détail (une ligne par nom résolu) : affichés, mais ni comparés ni résumés.
    public var mainFacts: [LinkCheckFact] { facts.filter { !$0.isDetail } }
}

/// Un bilan complet.
public struct LinkCheckResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    /// Clé du site (dossier de l'historique) et son nom au moment du bilan.
    public var siteKey: String?
    public var siteName: String
    /// Emplacement noté par le technicien (« Bureau 214 · prise B »).
    public var location: String
    public var interfaceName: String
    /// « Ethernet », « Wi-Fi ».
    public var interfaceKind: String
    public var steps: [LinkCheckStep]
    /// Durée totale, en secondes.
    public var duration: Double

    public init(id: UUID = UUID(), date: Date, siteKey: String? = nil, siteName: String = "", location: String = "",
                interfaceName: String, interfaceKind: String = "", steps: [LinkCheckStep], duration: Double = 0) {
        self.id = id
        self.date = date
        self.siteKey = siteKey
        self.siteName = siteName
        self.location = location
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.steps = steps.sorted { a, b in
            (LinkCheckStepKind.allCases.firstIndex(of: a.kind) ?? 0) < (LinkCheckStepKind.allCases.firstIndex(of: b.kind) ?? 0)
        }
        self.duration = duration
    }

    public func step(_ kind: LinkCheckStepKind) -> LinkCheckStep? { steps.first { $0.kind == kind } }

    /// Verdict d'ensemble : l'étape la plus grave (non vérifié si rien n'a été mesuré).
    public var overall: LinkCheckStatus { steps.map(\.status).max() ?? .skipped }

    public func count(_ status: LinkCheckStatus) -> Int { steps.filter { $0.status == status }.count }

    /// « SW-ETG2-01 · port 1/22 » (nil sans voisin LLDP/CDP).
    public var switchPort: String? {
        guard let step = step(.switchPort), let name = step.fact("switch")?.value else { return nil }
        return [name, step.fact("port").map { "port \($0.value)" }].compactMap { $0 }.joined(separator: " · ")
    }

    public var vlan: String? { step(.vlan)?.fact("vlan")?.value }

    /// Titre du bilan : « Raccordement conforme », « 1 avertissement : Lien », « 2 échecs : DHCP, Passerelle ».
    public var headline: String {
        let nb = "\u{00A0}"
        let failures = steps.filter { $0.status == .failure }
        let warnings = steps.filter { $0.status == .warning }
        if !failures.isEmpty {
            let names = failures.map(\.kind.title).joined(separator: ", ")
            return (failures.count > 1 ? "\(failures.count) échecs" : "1 échec") + "\(nb): " + names
                + (warnings.isEmpty ? "" : " · \(warnings.count) avertissement\(warnings.count > 1 ? "s" : "")")
        }
        if !warnings.isEmpty {
            return (warnings.count > 1 ? "\(warnings.count) avertissements" : "1 avertissement") + "\(nb): "
                + warnings.map(\.kind.title).joined(separator: ", ")
        }
        if steps.allSatisfy({ $0.status == .skipped }) { return "Rien n’a pu être mesuré" }
        return "Raccordement conforme"
    }

    /// « 7 OK · 1 avertissement · 0 échec · 1 non vérifié »
    public var countsLabel: String {
        let ok = count(.ok), warn = count(.warning), fail = count(.failure), skip = count(.skipped)
        var parts = ["\(ok) OK", "\(warn) avertissement\(warn > 1 ? "s" : "")", "\(fail) échec\(fail > 1 ? "s" : "")"]
        if skip > 0 { parts.append("\(skip) non vérifié\(skip > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    /// Résumé d'une ligne (résultats récents, historique) : switch, port, VLAN, vitesse.
    public var oneLine: String {
        var parts: [String] = []
        if let sp = switchPort { parts.append(sp) }
        if let vlan { parts.append("VLAN \(vlan)") }
        if let speed = step(.lien)?.fact("vitesse")?.value { parts.append(speed) }
        if parts.isEmpty { parts.append(interfaceName) }
        return parts.joined(separator: " · ")
    }
}
