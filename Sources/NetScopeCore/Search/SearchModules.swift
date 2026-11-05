import Foundation

// Champs de recherche de chaque module. Un mot sans préfixe garde les colonnes de l'ancienne
// recherche du module (`searchFreeText`) : une recherche simple donne le même résultat qu'avant.

public extension SearchSchema {
    /// Scanner : appareils du scan.
    static let scanner = SearchSchema([
        .switchName, .type, .ip, .name, .mac, .vendor, .port, .vlan, .site, .openPort, .status, .range, .note,
    ], example: "switch:SW-ETG2 type:imprimante")

    /// Inventaire : fiches des appareils.
    static let inventaire = SearchSchema([
        .type, .switchName, .ip, .name, .mac, .vendor, .port, .vlan, .status, .range, .tag, .location, .wallJack,
        .owner, .asset, .note, .openPort, .site.with(example: "Laval"),
    ], example: "type:camera -etat:\"en ligne\"")

    /// Analyse : alertes et changements de l'inventaire.
    static let analyse = SearchSchema([
        .severity, .type.with(label: "Changement", example: "\"port de switch\""), .ip, .name, .mac,
        .status.with(example: "\"à traiter\""), .message.with(example: "conflit"), .site.with(example: "Laval"),
    ], example: "gravite:critique ip:10.182.")

    /// Surveillance : sondes.
    static let sondes = SearchSchema([
        .name.with(example: "passerelle"), .type.with(example: "http"), .target, .status.with(example: "alerte"),
    ], example: "type:ping etat:\"hors ligne\"")

    /// Surveillance : journal des alertes.
    static let journal = SearchSchema([
        .name.with(label: "Sonde", example: "passerelle"), .severity, .status.with(example: "résolue"), .message,
    ], example: "gravite:critique -etat:résolue")

    /// Surveillance : sondes et journal des alertes (chaque liste applique les critères qu'elle connaît).
    static let surveillance = SearchSchema(merging: [sondes, journal], example: "type:ping -etat:disponible")

    /// Switchs et ports : table MAC du switch affiché.
    static let switchs = SearchSchema([
        .port, .vlan, .name.with(label: "Appareil", example: "brother"), .ip, .mac, .vendor, .type,
        .status.with(label: "État du port", example: "up"), .poe, .speed, .source, .switchName, .site,
    ], example: "vlan:30 type:imprimante")

    /// Boîte à outils : liste des outils.
    static let outilsListe = SearchSchema([
        .name.with(label: "Outil", example: "dns"), SearchAttribute("groupe", label: "Groupe", aliases: ["group", "categorie"], example: "diagnostic"),
    ], example: "groupe:courriel")

    /// Boîte à outils : historique des résultats.
    static let outilsHistorique = SearchSchema([
        .name.with(label: "Outil", example: "dns"), SearchAttribute("groupe", label: "Groupe", aliases: ["group", "categorie"], example: "diagnostic"),
        .target.with(example: "exemple.ca"), .status.with(example: "échec"),
    ], example: "cible:exemple.ca etat:échec")

    /// Boîte à outils : outils et historique (chaque liste applique les critères qu'elle connaît).
    static let outils = SearchSchema(merging: [outilsListe, outilsHistorique], example: "groupe:courriel")

    /// Réglages : sections.
    static let reglages = SearchSchema([.section.with(example: "FortiGate")], example: "section:alertes")

    /// Accès distant : connexions enregistrées.
    static let acces = SearchSchema([
        .proto, .name.with(example: "core"), .ip.with(label: "Hôte", example: "10.182."), .port.with(example: "22"),
        .user, .folder, .note,
    ], example: "proto:ssh dossier:Réseau")

    /// Serveurs de test de débit.
    static let serveurs = SearchSchema([.city, .sponsor, .country, .source.with(example: "LibreSpeed"), .name],
                                       example: "ville:Montréal source:Ookla")

    /// Wi-Fi : réseaux du voisinage.
    static let wifi = SearchSchema([
        .ssid, .mac.with(label: "BSSID", example: "a4:2b"), .vendor.with(example: "Ubiquiti"), .channel, .band, .security,
    ], example: "bande:5 -securite:WPA3")

    /// Wi-Fi › FortiAP : bornes gérées par la FortiGate.
    static let wifiBornes = SearchSchema([
        .accessPoint.with(example: "AP-ACCUEIL"), .model.with(example: "FAP-231F"), .ip, .status.with(example: "hors ligne"),
        .channel, .band, .site,
    ], example: "borne:AP-ACCUEIL etat:\"hors ligne\"")

    /// Wi-Fi › FortiAP : clients associés.
    static let wifiClients = SearchSchema([
        .name.with(label: "Client", example: "portable"), .mac, .ip, .ssid, .accessPoint.with(example: "AP-ACCUEIL"),
        .band, .channel, .vlan, .site,
    ], example: "borne:AP-ACCUEIL bande:2,4")

    /// Wi-Fi › FortiAP : SSID diffusés.
    static let wifiSSID = SearchSchema([.ssid, .security, .vlan, .site], example: "-securite:WPA3")

    /// Wi-Fi › FortiAP : AP voisins vus par les bornes.
    static let wifiVoisins = SearchSchema([
        .ssid, .mac.with(label: "BSSID", example: "a4:2b"), .vendor.with(example: "Ubiquiti"), .channel, .band, .security,
        .status.with(example: "non autorisé"), .accessPoint.with(label: "Vu par", example: "AP-ACCUEIL"), .site,
    ], example: "etat:\"non autorisé\"")

    /// Écran Wi-Fi : réseaux du voisinage et tableaux FortiAP (chaque tableau applique les
    /// critères qu'il connaît).
    static let wifiEcran = SearchSchema(merging: [wifi, wifiClients, wifiBornes, wifiSSID, wifiVoisins],
                                        example: "ssid:Bureau bande:5")
}

// MARK: - Scanner

public extension DeviceType {
    /// Mots reconnus par « type: » (libellé, nom interne et quelques synonymes anglais).
    var searchTerms: [String] {
        var terms = [label, rawValue]
        switch self {
        case .poste: terms += ["pc", "workstation", "ordinateur"]
        case .serveur: terms += ["server", "nas"]
        case .imprimante: terms += ["printer"]
        case .camera: terms += ["camera", "cam"]
        case .pointAcces: terms += ["ap", "access point", "wifi"]
        case .switch: terms += ["commutateur"]
        case .routeur: terms += ["router", "firewall", "pare-feu", "fortigate"]
        case .telephone: terms += ["phone", "cellulaire", "mobile"]
        case .telephoneIP: terms += ["voip", "sip", "ip phone", "telephonie", "tel ip", "poste telephonique"]
        case .console: terms += ["game", "jeu"]
        case .domotique: terms += ["home"]
        case .iot: terms += ["iot"]
        case .inconnu: terms += ["unknown"]
        }
        return terms
    }
}

/// Appareil du Scanner avec ce que l'app connaît en plus : site FortiGate, notes de la fiche.
/// Note 28 : `site:` vise aussi le vrai site de l'appareil (le site actif, nom du client compris).
public struct DeviceSearchItem: SearchableRecord {
    public static var searchSchema: SearchSchema { .scanner }

    public var device: Device
    public var site: String?
    /// Site (note 28) auquel appartiennent les résultats affichés.
    public var siteName: String?
    public var notes: [String]

    public init(_ device: Device, site: String? = nil, siteName: String? = nil, notes: [String] = []) {
        self.device = device
        self.site = site
        self.siteName = siteName
        self.notes = notes
    }

    public func searchValues(for field: SearchAttribute) -> [String] {
        let d = device
        switch field.key {
        case "ip": return [d.ip.description]
        case "nom": return [d.displayName, d.hostname, d.customName].compactMap { $0 }
        case "mac": return d.mac.map { [$0.formatted(.colon)] } ?? []
        case "type": return d.deviceType.searchTerms
        case "fab": return [d.vendorLabel]
        case "switch": return [d.switchName].compactMap { $0 }
        case "port": return [d.switchPort].compactMap { $0 }
        case "vlan": return d.vlan.map { [String($0)] } ?? []
        case "site": return [siteName, site].compactMap { $0 }
        case "tcp": return d.openPorts.map(String.init)
        case "etat": return d.isOnline ? ["En ligne", "online"] : ["Hors ligne", "offline"]
        case "plage": return [d.rangeLabel].compactMap { $0 }
        case "note": return notes
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche du Scanner.
    public var searchFreeText: [String] {
        let d = device
        var fields = [d.ip.description, d.displayName, d.vendorLabel, d.deviceType.label]
        if let mac = d.mac { fields += [mac.formatted(.colon), mac.formatted(.hyphen), mac.formatted(.cisco)] }
        fields += [d.hostname, d.customName, d.switchName, d.switchPort, d.rangeLabel].compactMap { $0 }
        if let vlan = d.vlan { fields.append("vlan \(vlan)") }
        fields += d.openPorts.map(String.init)
        return fields
    }
}

extension Device: SearchableRecord {
    public static var searchSchema: SearchSchema { .scanner }
    public func searchValues(for field: SearchAttribute) -> [String] { DeviceSearchItem(self).searchValues(for: field) }
    public var searchFreeText: [String] { DeviceSearchItem(self).searchFreeText }
}

// MARK: - Inventaire

extension InvRecord: SearchableRecord {
    public static var searchSchema: SearchSchema { .inventaire }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "ip": return [ip.description] + ipHistory.map { $0.ip.description }
        case "nom": return [displayName, hostname, annotations.customName].compactMap { $0 }
        case "mac": return mac.map { [$0.formatted(.colon)] } ?? []
        case "type": return type.searchTerms
        case "fab": return [vendorLabel]
        case "switch": return [switchName].compactMap { $0 }
        case "port": return [switchPort].compactMap { $0 }
        case "vlan": return vlan.map { [String($0)] } ?? []
        case "etat": return [status().label] + (isOnline ? ["online"] : ["offline"])
        case "plage": return [rangeLabel].compactMap { $0 }
        case "tag": return annotations.tags
        case "local": return [annotations.location]
        case "prise": return [annotations.wallJack]
        case "resp": return [annotations.owner]
        case "actif": return [annotations.assetNumber]
        case "note": return [annotations.notes]
        case "tcp": return openPorts.map(String.init)
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche de l'Inventaire.
    public var searchFreeText: [String] {
        var fields = [ip.description, displayName, vendorLabel, type.label]
        if let mac { fields += [mac.formatted(.colon), mac.formatted(.hyphen), mac.formatted(.cisco), mac.formatted(.bare)] }
        fields += [hostname, switchName, switchPort, rangeLabel].compactMap { $0 }
        fields += annotations.tags
        fields += [annotations.location, annotations.wallJack, "prise \(annotations.wallJack)", annotations.owner,
                   annotations.assetNumber, annotations.notes]
        fields += ipHistory.map { $0.ip.description }
        if let vlan { fields.append("vlan \(vlan)") }
        // Note 60 : modèle, numéros de série (saisi et détecté) et firmware.
        if !enteredSerial.isEmpty { fields.append(enteredSerial) }
        if let detected = detectedHardware {
            fields += [detected.model, detected.serialNumber, detected.firmware].compactMap { $0 }
        }
        return fields
    }
}

// MARK: - Analyse

/// Alerte de l'Analyse, avec la fiche de l'appareil concerné.
public struct InvEventSearchItem: SearchableRecord {
    public static var searchSchema: SearchSchema { .analyse }

    public var event: InvEvent
    public var deviceName: String
    public var mac: MACAddress?
    /// Site de l'inventaire de l'alerte (préfixe `site:`).
    public var siteName: String?

    public init(_ event: InvEvent, deviceName: String, mac: MACAddress? = nil, siteName: String? = nil) {
        self.event = event
        self.deviceName = deviceName
        self.mac = mac
        self.siteName = siteName
    }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "gravite": return [event.severity.label, event.severity.rawValue]
        case "type": return [event.kind.label, event.kind.rawValue]
        case "ip": return [event.ip.description]
        case "nom": return [deviceName]
        case "mac": return mac.map { [$0.formatted(.colon)] } ?? []
        case "etat":
            switch event.status {
            case .aTraiter: return ["À traiter", "nouveau", "open"]
            case .accepte: return ["Accepté", "accepted"]
            case .ignore: return ["Ignoré", "ignored"]
            }
        case "message": return [event.title, event.detail]
        case "site": return [siteName].compactMap { $0 }
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche de l'Analyse.
    public var searchFreeText: [String] {
        [event.title + " " + event.detail + " " + event.ip.description + " " + deviceName]
    }
}

// MARK: - Surveillance

/// Sonde de la Surveillance, avec son état du moment (« Disponible », « En alerte »…).
public struct MonProbeSearchItem: SearchableRecord {
    public static var searchSchema: SearchSchema { .sondes }

    public var probe: MonProbe
    public var stateLabels: [String]

    public init(_ probe: MonProbe, stateLabels: [String] = []) {
        self.probe = probe
        self.stateLabels = stateLabels
    }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "nom": return [probe.name, probe.subtitle]
        case "type": return [probe.kind.label, probe.kind.shortLabel, probe.kind.rawValue]
        case "cible": return [probe.target]
        case "etat": return stateLabels + (probe.isEnabled ? ["Active"] : ["En pause", "pause"])
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche des sondes.
    public var searchFreeText: [String] {
        [[probe.name, probe.target, probe.subtitle, probe.kind.label, probe.kind.shortLabel].joined(separator: " ")]
    }
}

extension MonAlert: SearchableRecord {
    public static var searchSchema: SearchSchema { .journal }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "nom": return [probeName]
        case "gravite": return [severity.label, severity.rawValue]
        case "etat":
            var states = [isResolved ? "Résolue" : "En cours"]
            if isAcknowledged { states.append("Accusée") }
            return states
        case "message": return [message, resolution].compactMap { $0 }
        default: return []
        }
    }
}

// MARK: - Accès distant

extension RemoteConnection: SearchableRecord {
    public static var searchSchema: SearchSchema { .acces }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "proto": return [proto.label, proto.rawValue, proto.fullName]
        case "nom": return [name]
        case "ip": return [host] + userAtHost
        case "port": return [String(port)]
        case "user": return [username, endUser].filter { !$0.isEmpty }
        case "dossier": return [folderLabel]
        case "note": return [note]
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche de l'Accès distant.
    public var searchFreeText: [String] {
        [name, host, String(port), proto.label, proto.rawValue, username, folder, note, endUser] + userAtHost + rustDeskGrouped
    }

    /// Note 52 : « admin@10.182.122.2 » (forme user@ip) trouve la connexion.
    private var userAtHost: [String] {
        username.isEmpty ? [] : ["\(username)@\(host)"]
    }

    /// Note 6 : « 123 456 789 » (ID RustDesk groupé, tel que l'usager le dicte) trouve le poste.
    private var rustDeskGrouped: [String] {
        isRustDeskByID ? [RustDeskID.grouped(host, separator: " ")] : []
    }
}

// MARK: - Test de débit

extension SpeedServer: SearchableRecord {
    public static var searchSchema: SearchSchema { .serveurs }

    public func searchValues(for field: SearchAttribute) -> [String] {
        switch field.key {
        case "ville": return [city].compactMap { $0 }
        case "operateur": return [sponsor].compactMap { $0 }
        case "pays": return [country].compactMap { $0 }
        case "source": return [source.label]
        case "nom": return [name, site].compactMap { $0 }
        default: return []
        }
    }

    /// Colonnes de l'ancienne recherche des serveurs.
    public var searchFreeText: [String] {
        [name, city ?? "", country ?? "", sponsor ?? "", site ?? "", source.label]
    }
}
