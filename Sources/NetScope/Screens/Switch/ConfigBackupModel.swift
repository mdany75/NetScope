import Foundation
import NetScopeCore

/// Note 40 (0.31.0) : sauvegarde des configurations du site actif (onglet « Configurations » de
/// Switchs et ports). FortiGate par l'API REST (GET, jeton du site) ; switchs par SSH (commandes de
/// lecture, identifiant SSH retenu, mot de passe du Trousseau). Historique dans
/// sites/<site>/configurations/<équipement>/<date>.conf. En démonstration et en capture : données
/// fixes (DevTools/ConfigBackupDemo.swift), rien n'est lu au Trousseau, sur le disque ni sur le réseau.
@MainActor
final class ConfigBackupModel: ObservableObject {
    static let shared = ConfigBackupModel()

    @Published private(set) var siteKey: String?
    @Published private(set) var settings = ConfigBackupSettings()
    /// Versions par équipement, la plus récente d'abord.
    @Published private(set) var versions: [String: [ConfigVersion]] = [:]
    @Published private(set) var running: Set<String> = []
    @Published private(set) var errors: [String: ConfigBackupError] = [:]
    /// Dernier résultat, en clair (« Configuration inchangée », « Nouvelle version · 3 lignes modifiées »).
    @Published private(set) var notices: [String: String] = [:]
    @Published var selectedID: String?
    /// Versions comparées (noms de fichier) : avant, après.
    @Published var compareOld: String?
    @Published var compareNew: String?
    /// Comparaison : seulement les blocs modifiés (sinon le fichier entier).
    @Published var changesOnly = true

    private var texts: [String: String] = [:]
    private var archive: ConfigBackupArchive?
    let isDemo: Bool

    private init(demo: Bool = RegEnvironment.isSandboxed) {
        isDemo = demo
        if demo {
            // Données prêtes dès le premier rendu (captures).
            let content = ConfigBackupDemo.make()
            settings = content.settings
            versions = content.versions
            texts = content.texts
            errors = content.errors
            notices = content.notices
            selectedID = "SW-CORE-01"
            defaultComparison()
        }
    }

    var pendingCount: Int { settings.pendingChanges.count }
    var isRunning: Bool { !running.isEmpty }

    // MARK: Site

    /// Site actif (ou « sans-site ») : réglages et historique relus quand il change.
    func load(siteKey key: String, equipments: [ConfigEquipment]) {
        if key != siteKey, isDemo {
            siteKey = key
        } else if key != siteKey {
            siteKey = key
            texts = [:]
            errors = [:]
            notices = [:]
            compareOld = nil
            compareNew = nil
            let archive = ConfigBackupArchive(siteFolder: SiteFiles.standard.folder(for: key))
            self.archive = archive
            settings = archive.loadSettings()
            versions = [:]
        }
        if let archive {
            for equipment in equipments where versions[equipment.id] == nil {
                versions[equipment.id] = archive.versions(of: equipment.id)
            }
        }
        if selectedID == nil || !equipments.contains(where: { $0.id == selectedID }) {
            selectedID = equipments.first { settings.pendingChanges[$0.id] != nil }?.id ?? equipments.first?.id
        }
        defaultComparison()
    }

    /// Comparaison par défaut : les deux dernières versions de l'équipement choisi.
    func defaultComparison() {
        guard let id = selectedID else { return }
        let list = versions[id] ?? []
        if compareNew == nil || !list.contains(where: { $0.id == compareNew }) { compareNew = list.first?.id }
        if compareOld == nil || !list.contains(where: { $0.id == compareOld }) { compareOld = list.dropFirst().first?.id }
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        compareOld = nil
        compareNew = nil
        defaultComparison()
    }

    // MARK: Équipements

    /// FortiGate du site (API) puis switchs relevés (SSH).
    func equipments(state: AppState, snapshots: [SNMPSwitchSnapshot]) -> [ConfigEquipment] {
        let fortigate = FortiGateStore.shared
        var list: [ConfigEquipment] = []
        for id in fortigate.siteSelection(ranges: state.checkedRanges, state: state).controllerIDs {
            guard let c = fortigate.controller(id), c.isEnabled else { continue }
            list.append(ConfigEquipment(name: "FortiGate " + c.displayName, host: c.config.cleanHost, kind: .fortigate, controllerID: id))
        }
        for snapshot in snapshots {
            var equipment = ConfigEquipment(name: snapshot.displayName, host: snapshot.host.description,
                                            kind: ConfigDeviceKind.detect(descr: snapshot.system.descr, name: snapshot.displayName))
            if equipment.kind == .fortigate { equipment.kind = .fortiswitch }
            equipment.kind = kind(of: equipment)
            equipment.credentialID = credentialID(of: equipment)
            list.append(equipment)
        }
        return list
    }

    func kind(of equipment: ConfigEquipment) -> ConfigDeviceKind? {
        if equipment.controllerID != nil { return .fortigate }
        return settings.equipment[equipment.id]?.kind ?? equipment.kind
    }

    /// Identifiant SSH retenu ; sinon celui dont la portée nomme l'équipement, ou le premier.
    func credentialID(of equipment: ConfigEquipment) -> UUID? {
        let ssh = RegRemoteCredentialStore.shared.credentials.filter { $0.kind == .ssh }
        if let id = settings.equipment[equipment.id]?.credentialID, ssh.contains(where: { $0.id == id }) { return id }
        let named = ssh.first { $0.scope.localizedCaseInsensitiveContains(equipment.name) || $0.lastHost == equipment.host }
        return (named ?? ssh.first)?.id
    }

    // MARK: CLI des FortiGate (note 111)

    /// Identifiant SSH choisi pour la CLI de cette FortiGate, à cette adresse. Aucun repli sur un
    /// autre compte : un mot de passe ne part jamais vers une FortiGate qui ne lui a pas été associée.
    func cliCredential(of equipment: ConfigEquipment) -> RemoteCredential? {
        guard let controllerID = equipment.controllerID else { return nil }
        return credential(settings.cliCredentialID(controllerID: controllerID, host: equipment.host))
    }

    /// Même chose pour un site donné : ses réglages sont relus, l'onglet Configurations peut montrer
    /// un autre site ou ne pas avoir été ouvert.
    func cliCredential(of controller: FortiGateController, siteKey key: String) -> RemoteCredential? {
        let values = key == siteKey ? settings : ConfigBackupArchive(siteFolder: SiteFiles.standard.folder(for: key)).loadSettings()
        return credential(values.cliCredentialID(controllerID: controller.id, host: controller.config.cleanHost))
    }

    private func credential(_ id: UUID?) -> RemoteCredential? {
        guard let id else { return nil }
        return RegRemoteCredentialStore.shared.credentials.first { $0.id == id && $0.kind == .ssh }
    }

    func setCLICredential(_ credentialID: UUID?, for equipment: ConfigEquipment) {
        guard let controllerID = equipment.controllerID else { return }
        settings.cliAccounts[controllerID.uuidString] = credentialID.map { .init(credentialID: $0, host: equipment.host) }
        persist()
    }

    /// Essaie les deux commandes de lecture et dit ce qui a été lu.
    func testCLI(_ equipment: ConfigEquipment) async {
        guard !running.contains(equipment.id) else { return }
        errors[equipment.id] = nil
        notices[equipment.id] = nil
        if isDemo {
            notices[equipment.id] = "CLI lue (démonstration)\u{00A0}: rien n’est envoyé."
            return
        }
        guard let credential = cliCredential(of: equipment) else {
            errors[equipment.id] = ConfigBackupError(kind: .account, detail: "Aucun identifiant CLI pour \(equipment.name).")
            return
        }
        let vdom = equipment.controllerID.flatMap { FortiGateStore.shared.controller($0)?.config.vdom } ?? ""
        let target = ConfigSSHTarget(credential: credential, host: equipment.host)
        let service = RemoteCredential.keychainService(.ssh), account = credential.keychainAccount
        running.insert(equipment.id)
        let result = await Task.detached(priority: .userInitiated) {
            await FortiCLISSH.read(target, vdom: vdom, secret: UpdKeychain(service: service).string(for: account))
        }.value
        running.remove(equipment.id)
        switch result {
        case .success(let snapshot):
            let partial = snapshot.partialError.map { " Une commande refusée\u{00A0}: \($0.detail)" } ?? ""
            notices[equipment.id] = "CLI lue\u{00A0}: \(snapshot.leases.count) bail(s) DHCP, \(snapshot.arp.count) entrée(s) ARP." + partial
        case .failure(let error):
            errors[equipment.id] = error
        }
    }

    func setKind(_ kind: ConfigDeviceKind?, for id: String) {
        var entry = settings.equipment[id] ?? .init()
        entry.kind = kind
        settings.equipment[id] = entry
        persist()
    }

    func setCredential(_ credentialID: UUID?, for id: String) {
        var entry = settings.equipment[id] ?? .init()
        entry.credentialID = credentialID
        settings.equipment[id] = entry
        persist()
    }

    func setKeep(_ value: Int) {
        settings.keep = ConfigBackupSettings.clampedKeep(value)
        persist()
        guard let archive else { return }
        for id in versions.keys {
            archive.prune(id, keep: settings.keep)
            versions[id] = archive.versions(of: id)
        }
        defaultComparison()
    }

    /// Changement signalé vu : l'alerte disparaît.
    func markSeen(_ id: String) {
        settings.pendingChanges[id] = nil
        persist()
    }

    private func persist() {
        guard let archive else { return }
        try? archive.saveSettings(settings)
    }

    // MARK: Textes

    func text(of version: ConfigVersion) -> String? {
        if let cached = texts[version.url.path] { return cached }
        guard let archive, let text = archive.read(version) else { return nil }
        texts[version.url.path] = text
        return text
    }

    func version(_ name: String?, of id: String) -> ConfigVersion? {
        guard let name else { return nil }
        return versions[id]?.first { $0.id == name }
    }

    /// Différences entre les deux versions choisies (secrets masqués).
    func comparison(for id: String) -> (old: ConfigVersion, new: ConfigVersion, diff: ConfigDiff)? {
        guard let new = version(compareNew, of: id), let old = version(compareOld, of: id),
              let newText = text(of: new), let oldText = text(of: old) else { return nil }
        let (first, second) = old.date <= new.date ? (old, new) : (new, old)
        let (a, b) = old.date <= new.date ? (oldText, newText) : (newText, oldText)
        return (first, second, ConfigDiff.make(old: a, new: b))
    }

    // MARK: Sauvegarde

    /// « Accepter l'empreinte » : la clé n'est enregistrée dans known_hosts que si celle que
    /// présente l'équipement est exactement l'empreinte affichée ; la sauvegarde suit, en mode strict.
    func acceptHostKey(for equipment: ConfigEquipment) {
        guard let shown = errors[equipment.id]?.fingerprint, !running.contains(equipment.id) else { return }
        errors[equipment.id] = nil
        if isDemo {
            Task { await backup(equipment) }
            return
        }
        // FortiGate : seulement son identifiant CLI, jamais un autre compte par défaut.
        let chosen = equipment.controllerID != nil ? cliCredential(of: equipment)
            : credentialID(of: equipment).flatMap { id in RegRemoteCredentialStore.shared.credentials.first { $0.id == id } }
        guard let credential = chosen else {
            errors[equipment.id] = ConfigBackupError(kind: .account, detail: "Aucun identifiant SSH pour \(equipment.name).")
            return
        }
        let target = ConfigSSHTarget(credential: credential, host: equipment.host)
        running.insert(equipment.id)
        Task {
            let trusted = await ConfigBackupSSH.trustHostKey(target, fingerprint: shown)
            running.remove(equipment.id)
            switch trusted {
            case .failure(let error): errors[equipment.id] = error
            case .success:
                if equipment.controllerID != nil { await testCLI(equipment) } else { await backup(equipment) }
            }
        }
    }

    func backupAll(_ list: [ConfigEquipment]) async {
        await withTaskGroup(of: Void.self) { group in
            for equipment in list where !running.contains(equipment.id) {
                group.addTask { await self.backup(equipment) }
            }
        }
    }

    func backup(_ equipment: ConfigEquipment) async {
        guard !running.contains(equipment.id) else { return }
        running.insert(equipment.id)
        errors[equipment.id] = nil
        notices[equipment.id] = nil
        defer { running.remove(equipment.id) }
        if isDemo {
            try? await Task.sleep(nanoseconds: 600_000_000)
            settings.lastChecked[equipment.id] = Date()
            notices[equipment.id] = "Configuration inchangée depuis la dernière version."
            return
        }
        let result: Result<String, ConfigBackupError>
        switch kind(of: equipment) {
        case .none:
            result = .failure(ConfigBackupError(kind: .unknownKind, detail: "Type de \(equipment.name) inconnu."))
        case .fortigate?:
            result = await readFortiGate(equipment)
        case let kind?:
            result = await readSwitch(equipment, kind: kind)
        }
        switch result {
        case .failure(let error):
            errors[equipment.id] = error
        case .success(let text):
            store(text, for: equipment)
        }
    }

    private func store(_ content: String, for equipment: ConfigEquipment) {
        guard let archive else { return }
        let now = Date()
        do {
            let outcome = try archive.save(content, for: equipment.id, at: now, keep: settings.keep)
            settings.lastChecked[equipment.id] = now
            versions[equipment.id] = archive.versions(of: equipment.id)
            switch outcome {
            case .unchanged:
                notices[equipment.id] = "Configuration inchangée depuis la dernière version."
            case .saved(let version, let previous, let changed):
                texts[version.url.path] = content
                if changed, let previous {
                    settings.pendingChanges[equipment.id] = version.date
                    let diff = text(of: previous).map { ConfigDiff.make(old: $0, new: content) }
                    notices[equipment.id] = "Configuration modifiée" + (diff.map { "\u{00A0}: +\($0.added) −\($0.removed) lignes" } ?? "") + "."
                    if selectedID == equipment.id {
                        compareNew = version.id
                        compareOld = previous.id
                    }
                } else {
                    notices[equipment.id] = "Première version gardée."
                }
            }
            persist()
            defaultComparison()
        } catch {
            errors[equipment.id] = ConfigBackupError(kind: .launch, detail: "Écriture impossible\u{00A0}: \(error.localizedDescription)")
        }
    }

    private func readFortiGate(_ equipment: ConfigEquipment) async -> Result<String, ConfigBackupError> {
        let fortigate = FortiGateStore.shared
        guard let id = equipment.controllerID, let c = fortigate.controller(id) else {
            return .failure(ConfigBackupError(kind: .notReady, detail: "FortiGate du site introuvable."))
        }
        let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: [.init(controllerID: id, site: c.displayName, reason: .activeSite)]))
        if let reason = targets.blocked[id] { return .failure(ConfigBackupError(kind: .notReady, detail: reason)) }
        guard let (controller, token) = targets.ready.first else {
            return .failure(ConfigBackupError(kind: .notReady, detail: "Aucun jeton enregistré pour cette FortiGate."))
        }
        return await Self.fetchFortiGate(config: controller.config, token: token)
    }

    nonisolated private static func fetchFortiGate(config: FortiGateConfig, token: String) async -> Result<String, ConfigBackupError> {
        let transport = FortiURLSessionTransport(config: config, token: token)
        return await ConfigBackupFortiGate.fetch(transport: transport, token: token)
    }

    private func readSwitch(_ equipment: ConfigEquipment, kind: ConfigDeviceKind) async -> Result<String, ConfigBackupError> {
        guard let credentialID = credentialID(of: equipment),
              let credential = RegRemoteCredentialStore.shared.credentials.first(where: { $0.id == credentialID }) else {
            return .failure(ConfigBackupError(kind: .account, detail: "Aucun identifiant SSH pour \(equipment.name)."))
        }
        let target = ConfigSSHTarget(credential: credential, host: equipment.host)
        let service = RemoteCredential.keychainService(.ssh), account = credential.keychainAccount
        return await Task.detached(priority: .userInitiated) {
            let secret = UpdKeychain(service: service).string(for: account)
            return await ConfigBackupSSH.run(target, kind: kind, secret: secret)
        }.value
    }
}
