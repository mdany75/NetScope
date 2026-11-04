import Foundation
import NetScopeCore
import SwiftUI

/// Inventaire permanent partagé par les écrans Inventaire, Analyse et Carte du réseau.
/// Il se nourrit de `AppState.devices` : chaque fin de scan est fusionnée dans `InventoryStore`.
/// En démonstration ou pendant les captures, rien n'est lu ni écrit sur le disque.
@MainActor
final class InvModel: ObservableObject {
    static let shared = InvModel()

    @Published private(set) var store: InventoryStore
    /// Fiche ouverte dans l'écran Inventaire.
    @Published var selectedKey: String?
    /// Message bref affiché sous la barre d'outils (« Fiche enregistrée »).
    @Published var toast: String?
    /// Types choisis à la main pour des appareils sans MAC et encore sans fiche, par IP, pour cette
    /// session seulement (note 20 ; voir Shared/DeviceTypeMenu.swift).
    @Published var sessionTypes: [String: DeviceType] = [:]

    let isEphemeral: Bool
    private let url: URL
    private var lastSignature: Int?
    private var pending: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        url = InventoryStore.defaultURL
        if isEphemeral {
            store = InventoryStore()
        } else {
            do {
                store = try InventoryStore.load(from: url)
            } catch {
                // Fichier illisible : on le met de côté plutôt que de l'écraser.
                let aside = url.deletingPathExtension()
                    .appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                NSLog("NetScope : inventaire illisible, mis de côté dans %@ : %@", aside.path, error.localizedDescription)
                store = InventoryStore()
            }
        }
    }

    // MARK: Fusion des scans

    /// Fusionne les appareils de l'état partagé ; `immediately` false : attend la fin du scan
    /// (1,5 s sans nouveau résultat) avant de fusionner.
    func observe(_ devices: [Device], immediately: Bool) {
        pending?.cancel()
        if immediately {
            ingest(devices)
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.ingest(devices)
        }
    }

    private func ingest(_ devices: [Device], at date: Date = Date()) {
        guard !devices.isEmpty else { return }
        let signature = Self.signature(devices)
        guard signature != lastSignature else { return }
        lastSignature = signature
        if isEphemeral && store.isEmpty && Launcher.isDemo {
            InvDemo.seed(&store, devices: devices, now: date)
        } else {
            let produced = store.merge(devices, at: date)
            // Conflit d'adresse IP relevé par la fusion : événement commun (notification, autres canaux).
            for event in produced where event.kind == .conflitIP && !event.baseline {
                NetScopeEventCenter.shared.publish(NetScopeEvent(
                    id: "conflit-" + event.id.uuidString, kind: .ipConflict, title: event.title, detail: event.detail,
                    date: event.date, link: .device(event.ip.description), source: "conflit-\(event.ip)"))
            }
        }
        save()
    }

    /// Empreinte des champs observés (un nom personnalisé changé ailleurs ne relance pas de fusion).
    private static func signature(_ devices: [Device]) -> Int {
        var hasher = Hasher()
        for device in devices {
            hasher.combine(device.ip)
            hasher.combine(device.mac)
            hasher.combine(device.isOnline)
            hasher.combine(device.hostname)
            hasher.combine(device.switchName)
            hasher.combine(device.switchPort)
            hasher.combine(device.openPorts)
            hasher.combine(device.lastSeen)
        }
        return hasher.finalize()
    }

    private func save() {
        guard !isEphemeral else { return }
        do {
            try store.save(to: url)
        } catch {
            NSLog("NetScope : enregistrement impossible de %@ : %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Fiches

    func record(_ key: String?) -> InvRecord? {
        key.flatMap { store.record($0) }
    }

    func setAnnotations(_ annotations: InvAnnotations, for key: String) {
        store.setAnnotations(annotations, for: key)
        save()
    }

    /// Retient le type choisi à la main (nil : type détecté) ; `all` : appareils du scan, fusionnés
    /// d'abord pour que chaque fiche existe. Renvoie le nombre d'appareils sans fiche (choix de session).
    @discardableResult
    func setManualType(_ type: DeviceType?, for devices: [Device], all: [Device]) -> Int {
        observe(all, immediately: true)
        var sessionOnly = 0
        for device in devices {
            if store.setManualType(type, for: device) {
                // La fiche fait foi : un ancien choix de session ne doit plus la masquer.
                if device.mac == nil { sessionTypes[device.id] = nil }
            } else {
                sessionTypes[device.id] = type
                sessionOnly += 1
            }
        }
        save()
        return sessionOnly
    }

    func toggleFavorite(_ key: String) {
        guard let record = store.record(key) else { return }
        store.setFavorite(!record.annotations.isFavorite, for: key)
        save()
    }

    func setFavorite(_ keys: [String]) {
        for key in keys { store.setFavorite(true, for: key) }
        save()
    }

    /// Alerte signalée par un outil ; faux si elle était déjà à traiter.
    @discardableResult
    func addAlert(_ event: InvEvent) -> Bool {
        let added = store.addAlert(event)
        if added { save() }
        return added
    }

    func setEventStatus(_ status: InvEventStatus, for id: UUID) {
        store.setEventStatus(status, for: id)
        save()
    }

    func absorb(_ duplicate: InvDuplicate) {
        store.absorb(duplicate.absorb, into: duplicate.keep)
        if selectedKey == duplicate.absorb { selectedKey = duplicate.keep }
        save()
    }

    /// Importe un CSV ; renvoie le compte rendu à afficher.
    func importCSV(_ text: String) -> String {
        do {
            let rows = try InvCSV.parse(text)
            let result = store.importRows(rows)
            save()
            return "Import CSV : \(result.created) fiche\(result.created > 1 ? "s" : "") créée\(result.created > 1 ? "s" : ""), "
                + "\(result.updated) complétée\(result.updated > 1 ? "s" : ""), \(result.skipped) inchangée\(result.skipped > 1 ? "s" : "")"
        } catch {
            return "Import impossible : \(error.localizedDescription)"
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Alertes

    /// Alertes (hors référence) depuis `since`, de la plus récente à la plus ancienne.
    func alerts(since: Date) -> [InvEvent] {
        store.events.filter { $0.isAlert && $0.date >= since }.sorted { $0.date > $1.date }
    }

    /// Alertes critiques ou importantes à traiter sur 24 h (compteur de la barre latérale, Analyse).
    var pendingAlertCount: Int {
        alerts(since: Date().addingTimeInterval(-86_400))
            .filter { $0.status == .aTraiter && $0.severity != .info }.count
    }

    func updateBadge(_ state: AppState) {
        let count = pendingAlertCount
        if state.sidebarBadges[.analyse] != (count > 0 ? count : nil) {
            state.sidebarBadges[.analyse] = count > 0 ? count : nil
        }
    }
}

extension View {
    /// Branche un écran sur l'inventaire : fusion à l'affichage, puis après chaque scan.
    @MainActor
    func feedsInventory(_ state: AppState) -> some View {
        let model = InvModel.shared
        return onAppear {
            model.observe(state.devices, immediately: true)
            model.updateBadge(state)
        }
        .onChange(of: state.devices) { _, devices in
            model.observe(devices, immediately: false)
        }
        // Le nombre d'événements plafonne à `maxEvents` et ne bouge pas quand une alerte est acceptée :
        // on suit directement le compteur.
        .onChange(of: model.pendingAlertCount) { _, _ in
            model.updateBadge(state)
        }
    }
}
