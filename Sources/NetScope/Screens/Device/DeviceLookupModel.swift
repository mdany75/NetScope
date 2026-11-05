import Foundation
import NetScopeCore
import SwiftUI

/// « Ouvrir une fiche » (écran Appareil sans appareil choisi) : saisie, suggestions parmi les
/// appareils connus et formulaire de saisie à la main. Rien n'est envoyé sur le réseau, sauf la
/// résolution d'un nom DNS quand l'utilisateur clique « Résoudre ».
@MainActor
final class DeviceLookupModel: ObservableObject {
    static let shared = DeviceLookupModel()

    /// Champ principal (IP, nom, MAC, fabricant).
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            highlighted = 0
            movedByKeys = false
            notice = nil
        }
    }
    /// Suggestion surlignée (flèches haut et bas, Entrée).
    @Published var highlighted = 0
    /// Vrai dès que l'utilisateur a choisi une suggestion aux flèches (pour cette saisie).
    @Published private(set) var movedByKeys = false
    /// Formulaire « Saisir à la main » ouvert.
    @Published var formShown = false {
        didSet {
            guard formShown != oldValue, !formShown else { return }
            resolveTask?.cancel()
            // Formulaire fermé : le focus revient au champ « Ouvrir une fiche ».
            searchFocusRequest += 1
        }
    }
    @Published var form = DeviceManualDraft()
    /// Incrémenté pour rendre le focus au champ de recherche (observé par le panneau).
    @Published private(set) var searchFocusRequest = 0
    /// Avis sous le champ (fiche qui ne peut pas s'ouvrir ici).
    @Published var notice: String?
    private var resolveTask: Task<Void, Never>?

    /// Appareils connus, relus à l'ouverture du panneau et quand les résultats changent.
    @Published private(set) var candidates: [DeviceLookupCandidate] = []
    private var candidatesSignature: Int?

    // MARK: Appareils connus

    /// Empreinte de ce qui change les suggestions : résultats, noms, saisies, site actif, inventaire.
    static func signature(_ state: AppState) -> Int {
        var hasher = Hasher()
        hasher.combine(state.devices.count)
        hasher.combine(state.devices.first?.lastSeen)
        hasher.combine(state.devices.last?.lastSeen)
        hasher.combine(state.customNames)
        hasher.combine(state.manualDevices)
        hasher.combine(SiteModel.shared.activeKey)
        hasher.combine(SiteModel.shared.sortedSites.count)
        let inventory = InvModel.shared
        hasher.combine(inventory.siteKey)
        hasher.combine(inventory.store.count)
        for record in inventory.store.records.values {
            hasher.combine(record.key)
            hasher.combine(record.annotations.customName)
            hasher.combine(record.ip)
        }
        return hasher.finalize()
    }

    /// Relit les appareils connus si les résultats ont changé depuis la dernière lecture.
    func refreshCandidates(_ state: AppState) {
        let signature = Self.signature(state)
        guard signature != candidatesSignature else { return }
        candidatesSignature = signature
        candidates = Self.buildCandidates(state)
    }

    /// Scanner du site actif, saisies à la main, Inventaire du site actif, puis les résultats et
    /// l'inventaire des autres sites ; doublons retirés (même site, même MAC, sinon même IP).
    static func buildCandidates(_ state: AppState) -> [DeviceLookupCandidate] {
        let inventory = InvModel.shared
        let sites = SiteModel.shared
        var list: [DeviceLookupCandidate] = []
        for device in inventory.withManualTypes(state.devices) {
            list.append(DeviceLookupCandidate(device: device, origin: .scanner, id: "scan|" + device.id))
        }
        for entry in state.siteManualDevices {
            list.append(DeviceLookupCandidate(device: entry.device, origin: .manual, id: "man|" + entry.id.uuidString))
        }
        for record in inventory.store.records.values {
            list.append(candidate(record, siteKey: nil, siteName: nil))
        }
        for site in sites.sortedSites {
            let key = SiteFiles.key(for: site.id)
            guard key != sites.activeKey else { continue }
            if let results = sites.storedResults(for: key) {
                for device in results.devices {
                    var copy = device
                    copy.customName = results.customNames[device.id] ?? device.customName
                    list.append(DeviceLookupCandidate(device: copy, origin: .otherSite, id: "site|\(key)|\(device.id)",
                                                      siteKey: key, siteName: site.displayName))
                }
            }
            for record in inventory.inventory(for: key).records.values {
                var item = candidate(record, siteKey: key, siteName: site.displayName)
                item.origin = .otherSite
                list.append(item)
            }
        }
        return DeviceLookup.deduplicated(list)
    }

    private static func candidate(_ record: InvRecord, siteKey: String?, siteName: String?) -> DeviceLookupCandidate {
        DeviceLookupCandidate(id: "inv|\(siteKey ?? "")|\(record.key)", origin: .inventory, siteKey: siteKey, siteName: siteName,
                              ip: record.hasAddress ? record.ip : nil, mac: record.mac, name: record.annotations.customName,
                              hostname: record.hostname.map { NamesFormat.display($0) },
                              vendor: record.annotations.customVendor ?? record.vendor, type: record.type,
                              isOnline: record.isOnline, lastSeen: record.lastSeen)
    }

    // MARK: Saisie

    var entry: DeviceEntry { DeviceEntry.parse(query) }

    var suggestions: [DeviceLookupMatch] { DeviceLookup.suggestions(for: query, in: candidates, limit: 8) }

    /// Une IP ou une MAC complète qu'aucun appareil connu ne porte : Entrée propose la saisie à la
    /// main tant qu'aucune suggestion n'est choisie aux flèches (les suggestions ne sont alors que
    /// des adresses voisines).
    func prefersForm(_ found: [DeviceLookupMatch]) -> Bool {
        guard !movedByKeys, found.first?.isExact != true else { return false }
        switch entry {
        case .ip, .mac: return true
        default: return false
        }
    }

    /// Suggestion surlignée (-1 : aucune, Entrée ouvre le formulaire).
    func highlightIndex(_ found: [DeviceLookupMatch]) -> Int {
        guard !found.isEmpty, !prefersForm(found) else { return -1 }
        return min(max(0, highlighted), found.count - 1)
    }

    /// Déplace la suggestion surlignée.
    func move(_ offset: Int, count: Int) {
        guard count > 0 else { return }
        let start = movedByKeys ? highlighted : (prefersForm(suggestions) ? (offset > 0 ? -1 : 0) : highlighted)
        highlighted = min(max(0, start + offset), count - 1)
        movedByKeys = true
    }

    /// Entrée : la suggestion surlignée ; sans suggestion (ou adresse complète inconnue), le
    /// formulaire prérempli.
    func submit(_ state: AppState) {
        let found = suggestions
        let index = highlightIndex(found)
        if found.indices.contains(index) {
            open(found[index].candidate, state: state)
        } else if entry.isUsable {
            showForm(prefilledFrom: entry)
        }
    }

    /// Ouvre la fiche d'un appareil connu.
    func open(_ candidate: DeviceLookupCandidate, state: AppState) {
        let inventory = InvModel.shared
        switch candidate.origin {
        case .scanner, .manual:
            if let ip = candidate.ip { finish { state.showDevice(ip.description) } }
        case .inventory, .otherSite:
            let siteKey = candidate.siteKey ?? SiteModel.shared.activeKey
            let siteName = candidate.siteName ?? SiteModel.shared.activeName
            // Fiche d'inventaire : l'appareil tel que l'inventaire le connaît.
            if candidate.id.hasPrefix("inv|") {
                let recordKey = String(candidate.id.split(separator: "|", maxSplits: 2).last ?? "")
                guard let record = inventory.inventory(for: siteKey).record(recordKey) else { return }
                guard record.hasAddress else {
                    // Sans adresse, pas de fiche Appareil : la fiche d'inventaire.
                    finish { state.navigate(NavDestination(.inventaire, focus: .record(site: siteKey, key: recordKey))) }
                    return
                }
                let device = Self.device(record)
                if let scanned = state.device(withID: device.id) {
                    // L'IP est déjà dans le Scanner du site actif : même appareil (même MAC), sa fiche ;
                    // sinon un autre appareil occupe cette IP ici, la fiche d'inventaire.
                    if candidate.siteKey == nil, Self.sameDevice(scanned, device) {
                        finish { state.showDevice(scanned.id) }
                    } else {
                        finish { state.navigate(NavDestination(.inventaire, focus: .record(site: siteKey, key: recordKey))) }
                    }
                    return
                }
                let source: ManualDeviceEntry.Source = candidate.siteKey == nil ? .inventory(site: siteName) : .otherSite(siteName)
                finish { state.openManual(ManualDeviceEntry(reference: device, source: source)) }
                return
            }
            // Résultats d'un autre site.
            guard let results = SiteModel.shared.storedResults(for: siteKey), let ip = candidate.ip,
                  var device = results.devices.first(where: { $0.ip == ip }) else { return }
            device.customName = results.customNames[device.id] ?? device.customName
            if let scanned = state.device(withID: device.id) {
                // Même IP dans le site actif : un autre appareil (autre site), sa fiche cacherait celle-ci.
                notice = "\(ip) est déjà dans le Scanner du site actif («\u{00A0}\(scanned.displayName)\u{00A0}»)\u{00A0}: "
                    + "la fiche de «\u{00A0}\(device.displayName)\u{00A0}» (site «\u{00A0}\(siteName)\u{00A0}») s’ouvre depuis ce site."
                return
            }
            finish { state.openManual(ManualDeviceEntry(reference: device, source: .otherSite(siteName))) }
        }
    }

    /// Même appareil : même MAC (ou l'une des deux inconnue).
    private static func sameDevice(_ scanned: Device, _ other: Device) -> Bool {
        guard let mac = scanned.mac, let otherMAC = other.mac else { return true }
        return mac == otherMAC
    }

    /// Rouvre un appareil consulté récemment : celui du Scanner (même MAC, sinon même IP), sinon
    /// la saisie gardée ; sinon l'adresse est remise dans le champ.
    func open(_ recent: DeviceRecentView, state: AppState) {
        if let mac = recent.mac, let device = state.devices.first(where: { $0.mac == mac }) {
            finish { state.showDevice(device.id) }
        } else if state.shownDevice(withID: recent.ip.description) != nil {
            finish { state.showDevice(recent.ip.description) }
        } else {
            query = recent.ip.description
        }
    }

    private func finish(_ action: () -> Void) {
        action()
        query = ""
        notice = nil
        formShown = false
    }

    /// Appareil tiré d'une fiche d'inventaire.
    static func device(_ record: InvRecord) -> Device {
        Device(ip: record.ip, mac: record.mac, vendor: record.annotations.customVendor ?? record.vendor,
               hostname: record.hostname, customName: record.annotations.customName, isOnline: record.isOnline,
               latencyMs: record.latencyMs, openPorts: record.openPorts, switchName: record.switchName,
               switchPort: record.switchPort, vlan: record.vlan, firstSeen: record.firstSeen, lastSeen: record.lastSeen,
               rangeLabel: record.rangeLabel, deviceType: record.type)
    }

    // MARK: Formulaire

    /// Ouvre le formulaire, prérempli avec ce que la saisie a reconnu.
    func showForm(prefilledFrom entry: DeviceEntry? = nil) {
        var draft = DeviceManualDraft()
        switch entry ?? .empty {
        case .ip(let ip): draft.ip = ip.description
        case .mac(let mac): draft.mac = mac.formatted(.upperColon)
        case .hostname(let name): draft.ip = name
        case .ambiguous(let mac, _): draft.mac = mac.formatted(.upperColon)
        case .empty, .invalid: break
        }
        resolveTask?.cancel()
        form = draft
        formShown = true
    }

    /// Résout le nom DNS du champ IP (seulement sur clic). La réponse n'est appliquée que si le
    /// brouillon et son champ IP n'ont pas changé entre-temps.
    func resolve() {
        guard case .hostname(let host) = DeviceEntry.parse(form.ip) else { return }
        guard !Launcher.isDemo else {
            form.resolveError = "Démonstration\u{00A0}: aucune requête DNS n’est envoyée."
            return
        }
        let draftID = form.draftID
        let typed = form.ip
        form.isResolving = true
        form.resolveError = nil
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            let result: Result<IPv4Address, Error>
            do { result = .success(try await PingResolver.resolveAsync(host)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.form.draftID == draftID else { return }
            self.form.isResolving = false
            guard self.form.ip == typed else { return }
            switch result {
            case .success(let address):
                self.form.ip = address.description
                // Après l'IP : changer l'IP efface le nom résolu.
                self.form.resolvedHostname = host
                if self.form.name.trimmingCharacters(in: .whitespaces).isEmpty { self.form.name = host }
            case .failure(let error):
                self.form.resolveError = "«\u{00A0}\(host)\u{00A0}» introuvable\u{00A0}: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Ouvre la fiche saisie (formulaire valide).
    func openForm(_ state: AppState) {
        guard let ip = form.parsedIP, form.macProblem == nil else { return }
        let entry = ManualDeviceEntry(ip: ip, mac: form.parsedMAC, name: form.name, hostname: form.resolvedHostname,
                                      type: form.type)
        let notes = form.notes
        resolveTask?.cancel()
        finish { state.openManual(entry, notes: notes) }
        form = DeviceManualDraft()
    }
}

/// Champs du formulaire « Saisir un appareil à la main ».
struct DeviceManualDraft: Equatable {
    /// Identifiant du brouillon (une réponse DNS tardive ne touche pas un autre brouillon).
    var draftID = UUID()
    var ip = "" {
        didSet {
            // Autre adresse : l'erreur et le nom résolus ne valent plus.
            guard ip != oldValue else { return }
            resolveError = nil
            resolvedHostname = nil
        }
    }
    var name = ""
    var mac = ""
    var type: DeviceType = .inconnu
    var notes = ""
    /// Nom DNS résolu par « Résoudre » (gardé comme nom d'hôte de la fiche).
    var resolvedHostname: String?
    var isResolving = false
    var resolveError: String?

    var parsedIP: IPv4Address? { IPv4Address(ip.trimmingCharacters(in: .whitespaces)) }

    /// Lecture du champ IP : vide, adresse, nom DNS à résoudre ou erreur.
    var ipEntry: DeviceEntry { DeviceEntry.parse(ip) }

    var parsedMAC: MACAddress? {
        switch DeviceEntry.parse(mac) {
        case .mac(let mac), .ambiguous(let mac, _): return mac
        default: return nil
        }
    }

    /// Erreur du champ MAC (facultatif : vide, aucune erreur).
    var macProblem: String? {
        switch DeviceEntry.parse(mac) {
        case .empty, .mac, .ambiguous: return nil
        case .invalid(let reason): return reason
        case .ip, .hostname: return "Adresse MAC illisible (ex. 94:DD:F8:18:15:7D)"
        }
    }

    /// Fabricant déduit de la MAC (base OUI de l'app).
    var vendorLabel: String? { parsedMAC.map { OUIDatabase.builtIn.label(for: $0) } }
}
