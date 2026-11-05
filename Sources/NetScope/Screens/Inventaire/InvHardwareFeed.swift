import Foundation
import NetScopeCore

/// Note 60 : fiche matériel remplie automatiquement. Reçoit ce que l'app lit déjà (fin de scan :
/// sysDescr des agents SNMP ; relevé des switchs : ENTITY-MIB ; Ressources SNMP ; firmware de la
/// FortiGate) et le pose dans l'inventaire du SITE de la lecture, à part des champs saisis. Le
/// bouton « Lire la fiche matériel » lit un seul appareil, à la demande. Jamais de balayage.
///
/// En démonstration et pendant les captures : aucune requête, les lectures viennent de
/// HardwareDetectDemo.
@MainActor
final class InvHardwareFeed: ObservableObject {
    static let shared = InvHardwareFeed()

    /// Fiches en cours de lecture (« site|clé »).
    @Published private(set) var reading: Set<String> = []
    /// Dernière lecture par Ressources, par adresse : une seule par heure (le relevé tourne en boucle).
    private var resourceReads: [String: Date] = [:]
    /// Lectures SNMP d'appareils encore sans fiche, par site (voir `inventoryMerged`).
    private var pending: [String: [Reading]] = [:]
    /// Relecture d'une même valeur : la date n'est réécrite dans un autre site qu'après ce délai.
    private static let refreshAge: TimeInterval = 12 * 3600

    private var isDemo: Bool { Launcher.isDemo || RegEnvironment.isSnapshot }

    /// Une lecture SNMP faite sur une adresse.
    private struct Reading {
        var host: IPv4Address
        var sysName: String
        var info: SNMPHardwareInfo
        var date: Date
    }

    static func id(site: String, key: String) -> String { site + "|" + key }

    func isReading(site: String, key: String) -> Bool { reading.contains(Self.id(site: site, key: key)) }

    // MARK: Lectures déjà faites par l'app

    /// Relevé des switchs (ENTITY-MIB et sysDescr) fait pour `site`.
    func recordSwitches(_ snapshots: [SNMPSwitchSnapshot], site: String) {
        let readings = snapshots.compactMap { snapshot -> Reading? in
            guard !snapshot.isViaController, let info = snapshot.hardware else { return nil }
            return Reading(host: snapshot.host, sysName: snapshot.system.name, info: info, date: snapshot.polledAt)
        }
        applySNMP(readings, site: site)
    }

    /// Fin de scan : sysDescr des agents SNMP qui ont répondu (imprimantes, NAS, switchs…).
    func recordDiscovery(_ found: [SNMPDiscovered], site: String, at date: Date = Date()) {
        let readings = found.compactMap { item -> Reading? in
            guard let info = SNMPHardwareInfo.combine(descr: item.sysDescr, objectID: item.sysObjectID, entity: nil) else { return nil }
            return Reading(host: item.host, sysName: item.sysName, info: info, date: date)
        }
        applySNMP(readings, site: site)
    }

    private func applySNMP(_ readings: [Reading], site: String) {
        guard !readings.isEmpty else { return }
        let model = InvModel.shared
        // Rien n'est écrit si rien ne change (relecture identique d'un autre site : pas d'écriture).
        var preview = model.inventory(for: site)
        let before = preview
        var unmatched: [Reading] = []
        for reading in readings {
            if preview.applySNMPHardware(reading.info, host: reading.host, sysName: reading.sysName, at: reading.date) == nil {
                unmatched.append(reading)
            }
        }
        // Appareil encore sans fiche (premier scan : la fusion dans l'inventaire suit de peu) :
        // la lecture attend la prochaine fusion de ce site (dix minutes au plus).
        if !unmatched.isEmpty {
            let fresh = (pending[site] ?? []).filter { old in !unmatched.contains { $0.host == old.host } }
            pending[site] = Array((fresh + unmatched).suffix(512))
        }
        guard Self.differs(before, preview, active: site == model.siteKey) else { return }
        model.mutate(site: site) { store in
            for reading in readings {
                store.applySNMPHardware(reading.info, host: reading.host, sysName: reading.sysName, at: reading.date)
            }
        }
    }

    /// L'inventaire de `site` vient de fusionner un scan : les lectures en attente y sont reposées.
    func inventoryMerged(site: String) {
        guard let waiting = pending.removeValue(forKey: site) else { return }
        let recent = waiting.filter { Date().timeIntervalSince($0.date) < 600 }
        let model = InvModel.shared
        var preview = model.inventory(for: site)
        let matched = recent.filter { preview.applySNMPHardware($0.info, host: $0.host, sysName: $0.sysName, at: $0.date) != nil }
        guard !matched.isEmpty else { return }
        model.mutate(site: site) { store in
            for reading in matched {
                store.applySNMPHardware(reading.info, host: reading.host, sysName: reading.sysName, at: reading.date)
            }
        }
    }

    /// Lecture du firmware d'une FortiGate (FortiGate, FortiSwitch, FortiAP) : rapprochée des fiches
    /// des seuls sites auxquels cette FortiGate est associée.
    func recordFirmware(_ report: FirmwareSiteReport) {
        let fortigate = FortiGateStore.shared
        let ip = fortigate.controller(report.controllerID).flatMap { IPv4Address($0.config.cleanHost) }
        let candidates = InvHardwareMatcher.candidates(from: report, fortigateIP: ip)
        guard !candidates.isEmpty else { return }
        let sites = SiteModel.shared
        var keys = sites.sites.filter { $0.fortiGateIDs.contains(report.controllerID) }.map { SiteFiles.key(for: $0.id) }
        // Aucun site enregistré : les plages libres (site actif) sont le seul inventaire.
        if sites.sites.isEmpty { keys = [sites.activeKey] }
        let model = InvModel.shared
        for key in keys {
            var preview = model.inventory(for: key)
            let before = preview
            preview.applyDetected(candidates)
            guard Self.differs(before, preview, active: key == model.siteKey) else { continue }
            model.mutate(site: key) { $0.applyDetected(candidates) }
        }
    }

    /// Ressources SNMP d'un appareil (v2c) : une lecture de la fiche matériel par heure au plus.
    func resourcesPolled(host: IPv4Address, community: String) {
        guard !isDemo, !community.isEmpty else { return }
        let now = Date()
        if let last = resourceReads[host.description], now.timeIntervalSince(last) < 3600 { return }
        resourceReads[host.description] = now
        let site = SiteModel.shared.activeKey
        Task {
            let client = SNMPClient(target: SNMPTarget(host: host, community: community, timeout: 2, retries: 1))
            guard let info = try? await SNMPHardwareReader.read(client: client), SiteModel.shared.activeKey == site else { return }
            applySNMP([Reading(host: host, sysName: "", info: info, date: Date())], site: site)
        }
    }

    /// Vrai si l'inventaire a changé : une valeur, ou (site actif seulement, ou lecture ancienne)
    /// la date de lecture.
    private static func differs(_ before: InventoryStore, _ after: InventoryStore, active: Bool) -> Bool {
        for record in after.sortedRecords {
            guard let new = record.detectedHardware else { continue }
            guard let old = before.record(record.key)?.detectedHardware else { return true }
            if !old.sameValues(as: new) { return true }
            if old.readAt != new.readAt && (active || new.readAt.timeIntervalSince(old.readAt) > refreshAge) { return true }
        }
        return false
    }

    // MARK: « Lire la fiche matériel »

    /// Lit la fiche d'un appareil du site actif : FortiGate d'abord pour un appareil Fortinet (si une
    /// FortiGate est associée au site), sinon SNMP v2c (communauté du switch ou des Identifiants),
    /// sinon SNMP v3 (Identifiants). Le résultat va dans cette fiche seulement.
    func read(_ record: InvRecord, site: String, state: AppState) {
        let model = InvModel.shared
        guard site == model.siteKey else {
            model.show("Lecture possible seulement pour les appareils du site actif")
            return
        }
        guard record.hasAddress else {
            model.show("Appareil sans adresse IP\u{00A0}: rien à lire")
            return
        }
        let id = Self.id(site: site, key: record.key)
        guard !reading.contains(id) else { return }
        reading.insert(id)
        Task {
            defer { reading.remove(id) }
            let message = await perform(record, site: site, state: state)
            model.show(message)
        }
    }

    private func perform(_ record: InvRecord, site: String, state: AppState) async -> String {
        let model = InvModel.shared
        let ip = record.ip
        if isDemo {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let detected = HardwareDetectDemo.reading(for: record, now: Date()) else {
                return "Pas de réponse SNMP de \(ip) (démonstration)"
            }
            model.mutate(site: site) { $0.setDetectedHardware(detected, for: record.key) }
            return "Fiche matériel lue\u{00A0}: \(Self.summary(detected))"
        }

        // Appareil Fortinet : la FortiGate du site connaît son modèle, son numéro et sa version.
        if record.vendorLabel.lowercased().contains("fortinet") {
            let ids = FirmwareStore.shared.controllerIDs(forSiteKeys: [site], state: state)
            if !ids.isEmpty, FirmwareStore.shared.canRead(ids) {
                await FirmwareStore.shared.refresh(ids)
                if let detected = model.inventory(for: site).record(record.key)?.detectedHardware,
                   detected.source == .fortigate, Date().timeIntervalSince(detected.readAt) < 120 {
                    return "Fiche matériel lue par la FortiGate\u{00A0}: \(Self.summary(detected))"
                }
            }
        }

        let switches = SwitchStore.shared
        await switches.loadVault()
        let community = switches.community(for: ip.description)
        do {
            let info: SNMPHardwareInfo?
            if !community.isEmpty {
                let client = SNMPClient(target: SNMPTarget(host: ip, community: community, timeout: 2, retries: 1))
                info = try await SNMPHardwareReader.read(client: client)
            } else {
                let saved = await Task.detached(priority: .userInitiated) { RegSNMPCredentials.load() }.value
                guard let saved, !saved.v3User.isEmpty else {
                    return "Aucun identifiant SNMP\u{00A0}: saisissez une communauté ou un utilisateur v3 dans Réglages › Identifiants"
                }
                info = try await SNMPHardwareReader.read(v3: SNMPv3Client(host: ip, credentials: saved.v3Credentials, timeout: 2, retries: 1))
            }
            guard SiteModel.shared.activeKey == site else { return "Site changé pendant la lecture\u{00A0}: rien n’est enregistré" }
            guard let info else { return "\(ip) a répondu, mais sans modèle, numéro de série ni version" }
            let detected = InvDetectedHardware(snmp: info, readAt: Date())
            model.mutate(site: site) { $0.setDetectedHardware(detected, for: record.key) }
            return "Fiche matériel lue\u{00A0}: \(Self.summary(detected))"
        } catch is CancellationError {
            return "Lecture annulée"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Lecture SNMP impossible"
        }
    }

    /// « C9300-48P · FOC2331X0QZ · 17.09.04a ».
    static func summary(_ detected: InvDetectedHardware) -> String {
        [detected.model, detected.serialNumber, detected.firmware].compactMap { $0 }.joined(separator: " · ")
    }

    /// « Reprendre » : le numéro détecté devient le numéro saisi de la fiche (s'il est vide).
    func adoptSerial(_ record: InvRecord, site: String) {
        let model = InvModel.shared
        let done = model.mutate(site: site) { $0.adoptDetectedSerial(for: record.key) } ?? false
        if done, let serial = model.inventory(for: site).record(record.key)?.enteredSerial {
            model.show("Numéro de série repris\u{00A0}: \(serial)")
        }
    }
}
