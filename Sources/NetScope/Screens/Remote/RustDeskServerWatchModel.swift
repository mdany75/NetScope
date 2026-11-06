import AppKit
import Foundation
import NetScopeCore

/// Note 87 (0.33.0) : suivi du serveur RustDesk, en lecture seulement. Noms et notes par ID,
/// historique des demandes jour après jour, clé publique (alerte si elle change), mises à jour à
/// vérifier (lecture détaillée avec sudo, versions publiées en ligne au clic ou une fois par jour),
/// journaux de hbbs et hbbr, copie chiffrée du dossier de données, tentatives suspectes, site
/// probable et association d'un ID à une fiche (proposée, confirmée par l'utilisateur).
/// En démonstration et en capture : données fixes, aucun ssh, aucun accès en ligne, aucun Trousseau.
@MainActor
final class RustDeskServerWatchModel: ObservableObject {
    static let shared = RustDeskServerWatchModel()

    /// Mot de passe sudo au Trousseau (service RustDesk), lié au compte du serveur.
    nonisolated static let sudoPrefix = "tableau-serveur-sudo:"
    /// Clé de chiffrement des copies du dossier de données (Trousseau de ce Mac).
    nonisolated static let backupKeyAccount = "sauvegarde-serveur-cle"

    @Published private(set) var contents = RustDeskWatchStore.Contents()
    @Published private(set) var detail: RustDeskServerReading?
    @Published private(set) var detailReading = false
    @Published private(set) var detailError: String?
    @Published private(set) var checkingVersions = false
    @Published private(set) var logs: [RustDeskLogLine] = []
    @Published private(set) var logsReading = false
    @Published private(set) var logsError: String?
    @Published var logSearch = ""
    @Published var logID = ""
    @Published private(set) var backupRunning = false
    @Published private(set) var backupMessage: (text: String, ok: Bool)?
    @Published private(set) var hasSudoPassword = false
    /// Fiche ouverte d'un ID (nom et note) ou d'une IP de technicien.
    @Published var editing: RustDeskNoteTarget?
    /// Association proposée pour un ID.
    @Published var associating: RustDeskAssociationRequest?

    private let store: RustDeskWatchStore?
    private let sandboxed: Bool
    private var lastDetailAccount: String?
    /// Dernière lecture détaillée tentée (réussie ou non) : relancée seule une fois par jour au plus.
    private var lastDetailAttempt: Date?
    /// Sudo a refusé le mot de passe envoyé : plus d'envoi automatique avant qu'il change ou
    /// que l'utilisateur clique sur « Vérifier maintenant » (pam_faillock compte chaque échec).
    private var sudoRefused = false
    /// Contenu lu ou écrit en dernier (fusion à trois avec le fichier synchronisé, note 86).
    private var baseline = RustDeskWatchStore.Contents()

    private init() {
        sandboxed = RegEnvironment.isSandboxed
        store = sandboxed ? nil : RustDeskWatchStore.standard
        if RegEnvironment.isDemo {
            contents = RustDeskServerDemo.watch(now: Date())
            detail = RustDeskServerDemo.detail(now: Date())
            logs = RustDeskServerDemo.logs(now: Date())
            hasSudoPassword = true
        } else {
            contents = store?.load() ?? RustDeskWatchStore.Contents()
            baseline = contents
            refreshSudoFlag()
        }
    }

    // MARK: Lecture du tableau de bord

    /// Chaque lecture réussie : demandes gardées jour après jour, clé publique observée,
    /// lecture détaillée et versions publiées une fois par jour.
    func ingest(_ status: RustDeskServerStatus) {
        guard !RegEnvironment.isDemo else { return }
        var updated = contents
        updated.history = RustDeskRequestArchive.merge(updated.history, adding: status.punchRequests, now: Date())
        updated.observeKey(status.publicKey.value, now: Date())
        if updated != contents {
            let keyChanged = updated.keyChangedAt != nil && contents.keyChangedAt == nil
            contents = updated
            save()
            if keyChanged { AppLog.shared.warning("RustDesk", "Clé publique du serveur changée.") }
        }
        let account = RustDeskServerModel.shared.accountLabel
        if lastDetailAccount != account || RustDeskVersionCheck.isDue(lastCheck: lastDetailAttempt, now: Date()) {
            readDetails(automatic: true)
        }
        if RustDeskVersionCheck.isDue(lastCheck: contents.published.checkedAt, now: Date()) { checkPublished() }
    }

    /// Compte changé : la lecture détaillée et les journaux de l'ancien serveur sont oubliés.
    func accountChanged() {
        guard !RegEnvironment.isDemo else { return }
        detail = nil
        detailError = nil
        lastDetailAttempt = nil
        lastDetailAccount = nil
        sudoRefused = false
        logs = []
        logsError = nil
        refreshSudoFlag()
    }

    /// Version du client RustDesk de ce Mac (Info.plist de l'app), « 1.4.2 » en démonstration.
    static var clientVersion: String? {
        if RegEnvironment.isDemo { return "1.4.2" }
        guard let url = RustDeskModel.shared.applicationURL else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: Sudo

    private var sudoKey: String? {
        RustDeskServerModel.shared.settings.accountKey.map { Self.sudoPrefix + $0 }
    }

    private func refreshSudoFlag() {
        guard !sandboxed else { return }
        hasSudoPassword = sudoKey.map { RustDeskModel.keychain.string(for: $0) != nil } ?? false
    }

    /// Enregistre (ou efface, si vide) le mot de passe sudo du compte (Trousseau seulement).
    func setSudoPassword(_ value: String) {
        guard let key = sudoKey else { return }
        hasSudoPassword = !value.isEmpty
        sudoRefused = false
        guard !sandboxed else { return }
        do {
            try RustDeskModel.keychain.set(value.isEmpty ? nil : value, for: key)
        } catch {
            AppLog.shared.error("RustDesk", "Mot de passe sudo non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Le compte SSH s'authentifie par mot de passe (aucune clé privée) : ce mot de passe peut
    /// servir à sudo. Avec une clé, le secret du compte est peut-être sa phrase de passe : jamais
    /// envoyé à sudo.
    var sshPasswordUsableForSudo: Bool {
        guard let account = try? RustDeskServerModel.shared.resolvedAccount().get() else { return false }
        return account.keyPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Mot de passe sudo : celui enregistré, sinon celui du compte SSH s'il s'authentifie par mot de
    /// passe ; sinon aucun (sudo -n). Lecture automatique après un refus : aucun.
    private func sudoPassword(automatic: Bool) -> String? {
        guard !sandboxed, !(automatic && sudoRefused) else { return nil }
        if let key = sudoKey, let value = RustDeskModel.keychain.string(for: key) { return value }
        return sshPasswordUsableForSudo ? RustDeskServerModel.shared.secret() : nil
    }

    // MARK: Lectures à la demande

    private func runDetail(_ script: String, timeout: TimeInterval = 120, limit: Int = 4_000_000, automatic: Bool = false,
                           completion: @escaping @MainActor (Result<String, RustDeskServerReadError>) -> Void) {
        guard let account = try? RustDeskServerModel.shared.resolvedAccount().get() else {
            completion(.failure(RustDeskServerReadError(kind: .account, detail: "Aucun compte SSH n’est choisi pour le serveur.")))
            return
        }
        let secret = RustDeskServerModel.shared.secret()
        let sudo = sudoPassword(automatic: automatic)
        Task {
            let result = await RustDeskServerSSH.runDetail(account, secret: secret, sudoPassword: sudo, script: script,
                                                           timeout: timeout, outputLimit: limit)
            completion(result)
        }
    }

    /// Mises à jour du système, version de hbbs, conteneurs, images et clé (avec sudo si besoin).
    /// `automatic` : lancée par une lecture du tableau de bord (pas de mot de passe après un refus).
    func readDetails(automatic: Bool = false) {
        guard !detailReading else { return }
        if RegEnvironment.isDemo {
            detail = RustDeskServerDemo.detail(now: Date())
            return
        }
        guard !sandboxed else { return }
        detailReading = true
        let account = RustDeskServerModel.shared.accountLabel
        lastDetailAttempt = Date()
        lastDetailAccount = account
        runDetail(RustDeskServerDetailScript.details, automatic: automatic) { result in
            self.detailReading = false
            switch result {
            case .success(let output):
                let parsed = RustDeskServerReading.parse(output, readAt: Date())
                self.detail = parsed
                if parsed.sudo == "refuse" { self.sudoRefused = true } else if parsed.sudo == "ok" { self.sudoRefused = false }
                self.detailError = parsed.sudo == "refuse" ? "sudo refusé\u{00A0}: mot de passe sudo absent ou incorrect (Réglages › RustDesk). Lecture partielle\u{00A0}; plus d’envoi automatique avant «\u{00A0}Vérifier maintenant\u{00A0}»." : nil
                var updated = self.contents
                updated.observeKey(parsed.publicKey.value, now: Date())
                if updated != self.contents {
                    self.contents = updated
                    self.save()
                }
            case .failure(let error):
                self.detailError = error.title + "\u{00A0}: " + error.detail
            }
        }
    }

    /// « Vérifier maintenant » : lecture détaillée et versions publiées (Docker Hub, GitHub).
    func checkNow() {
        sudoRefused = false
        readDetails()
        checkPublished()
    }

    /// Versions publiées : jamais en démonstration, en capture ni dans les tests.
    func checkPublished() {
        guard !checkingVersions, !sandboxed, !RegEnvironment.isDemo else { return }
        checkingVersions = true
        Task {
            var published = RustDeskPublishedVersions(checkedAt: Date())
            var failures: [String] = []
            func fetch(_ url: URL) async -> Data? {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("NetScope", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    failures.append(url.host ?? url.absoluteString)
                    return nil
                }
                return data
            }
            published.hubDigest = await fetch(RustDeskVersionCheck.dockerHubURL).flatMap(RustDeskVersionCheck.dockerHubDigest)
            published.server = await fetch(RustDeskVersionCheck.serverReleaseURL).flatMap(RustDeskVersionCheck.gitHubTag)
            published.client = await fetch(RustDeskVersionCheck.clientReleaseURL).flatMap(RustDeskVersionCheck.gitHubTag)
            published.error = failures.isEmpty ? nil : "Lecture impossible\u{00A0}: " + Set(failures).sorted().joined(separator: ", ")
            self.checkingVersions = false
            self.contents.published = published
            self.save()
        }
    }

    func readLogs() {
        guard !logsReading else { return }
        if RegEnvironment.isDemo {
            logs = RustDeskServerDemo.logs(now: Date())
            return
        }
        guard !sandboxed else { return }
        logsReading = true
        runDetail(RustDeskServerDetailScript.logs, timeout: 90) { result in
            self.logsReading = false
            switch result {
            case .success(let output):
                self.logs = RustDeskLogLine.parse(output)
                self.logsError = self.logs.isEmpty ? "Aucun journal lu (conteneurs hbbs et hbbr, ou services rustdesk-hbbs et rustdesk-hbbr)." : nil
            case .failure(let error):
                self.logsError = error.title + "\u{00A0}: " + error.detail
            }
        }
    }

    var filteredLogs: [RustDeskLogLine] {
        RustDeskLogLine.filter(logs, search: logSearch, id: logID)
    }

    // MARK: Sauvegarde

    var lastBackup: Date? { contents.backups.max() }

    static var backupFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NetScope/Sauvegardes RustDesk", isDirectory: true)
    }

    /// Copie chiffrée sur ce Mac du dossier de données (clés et base) ; rien n'est écrit sur le serveur.
    func backup() {
        guard !backupRunning else { return }
        if RegEnvironment.isDemo {
            backupMessage = ("Démonstration\u{00A0}: aucune copie faite.", true)
            return
        }
        guard !sandboxed else { return }
        backupRunning = true
        backupMessage = nil
        runDetail(RustDeskServerDetailScript.backup, timeout: 300, limit: 200_000_000) { result in
            self.backupRunning = false
            switch result {
            case .failure(let error):
                self.backupMessage = (error.title + "\u{00A0}: " + error.detail, false)
            case .success(let output):
                guard let archive = RustDeskBackupArchive.decode(output) else {
                    self.backupMessage = ("Aucune donnée reçue\u{00A0}: dossier introuvable ou sudo refusé (Réglages › RustDesk).", false)
                    return
                }
                do {
                    let key = try self.backupKey()
                    let sealed = try RustDeskBackupCrypto.seal(archive.archive, key: key)
                    let folder = Self.backupFolder
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let now = Date()
                    let url = folder.appendingPathComponent(RustDeskBackupCrypto.fileName(now))
                    try sealed.write(to: url, options: [.atomic, .completeFileProtection])
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    self.contents.backups = Array((self.contents.backups + [now]).sorted().suffix(50))
                    self.save()
                    self.backupMessage = ("Copie chiffrée de \(archive.folder) enregistrée (\(RustDeskServerFormat.bytes(Int64(sealed.count)))).", true)
                } catch {
                    self.backupMessage = ("Copie non enregistrée\u{00A0}: \(error.localizedDescription)", false)
                }
            }
        }
    }

    /// Clé AES du Trousseau (créée à la première copie).
    private func backupKey() throws -> Data {
        if let text = RustDeskModel.keychain.string(for: Self.backupKeyAccount), let data = Data(base64Encoded: text), data.count == 32 {
            return data
        }
        let key = RustDeskBackupCrypto.newKey()
        try RustDeskModel.keychain.set(key.base64EncodedString(), for: Self.backupKeyAccount)
        return key
    }

    func revealBackups() {
        guard !sandboxed else { return }
        let folder = Self.backupFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    // MARK: Clé publique

    /// L'utilisateur reconnaît la nouvelle clé : elle devient la clé connue, ici et dans les
    /// sondes « Serveur RustDesk » de Surveillance (sinon elles resteraient en panne).
    func acceptKey(_ key: String) {
        contents.knownKey = key
        contents.keyChangedAt = nil
        save()
        let monitor = MonStore.shared
        for var probe in monitor.probes where probe.kind == .rustdeskServer {
            probe.knownThreats = (probe.knownThreats ?? []).filter { !$0.hasPrefix(MonRustDeskChecks.keyPrefix) } + [MonRustDeskChecks.keyPrefix + key]
            monitor.save(probe)
        }
    }

    // MARK: Noms et notes

    /// Carnet complet : notes, carnet d'Accès distant, fiches d'inventaire (ID RustDesk).
    var book: [String: String] {
        RustDeskNames.merged(notes: contents.notes, book: RustDeskServerModel.shared.book, inventory: inventoryBook)
    }

    /// ID RustDesk → nom de la fiche (inventaire du site actif).
    var inventoryBook: [String: String] {
        var result: [String: String] = [:]
        for record in InvModel.shared.store.records.values {
            if let id = record.annotations.rustdeskID.flatMap(RustDeskID.parse), result[id] == nil { result[id] = record.displayName }
        }
        return result
    }

    /// Fiche d'inventaire qui porte cet ID (site actif).
    func record(for id: String) -> InvRecord? {
        let key = RustDeskNames.key(id)
        return InvModel.shared.store.records.values.first { $0.annotations.rustdeskID.flatMap(RustDeskID.parse) == key }
    }

    func note(for id: String) -> RustDeskIDNote? {
        contents.notes[RustDeskNames.key(id)]
    }

    /// Nom de l'ID (nom donné, carnet ou fiche) ; nil sinon.
    func name(for id: String) -> String? {
        RustDeskNames.resolve(id, notes: contents.notes, book: RustDeskServerModel.shared.book, inventory: inventoryBook)?.name
    }

    func setNote(_ id: String, name: String, note: String) {
        let key = RustDeskNames.key(id)
        guard !key.isEmpty else { return }
        let value = RustDeskIDNote(name: name.trimmingCharacters(in: .whitespaces), note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                   updatedAt: Date())
        contents.notes[key] = value.isEmpty ? nil : value
        save()
    }

    func technicianName(_ ip: String) -> String? {
        contents.technicians[ip].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setTechnician(_ ip: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        contents.technicians[ip] = trimmed.isEmpty ? nil : trimmed
        save()
    }

    // MARK: Site probable

    /// Adresses WAN des FortiGate lues (WAN) : (site, IP).
    var wanAddresses: [(site: String, ip: String)] {
        if RegEnvironment.isDemo { return RustDeskServerDemo.wanAddresses }
        var list: [(String, String)] = []
        for report in WANStore.shared.reports.values {
            for interface in report.report.interfaces {
                guard let ip = interface.ip?.description, !RustDeskSiteHint.isPrivate(ip) else { continue }
                list.append((report.site, ip))
            }
        }
        return list
    }

    func probableSite(_ ip: String) -> String? {
        RustDeskSiteHint.site(for: ip, wan: wanAddresses)
    }

    // MARK: Tentatives suspectes

    func suspicious(_ status: RustDeskServerStatus) -> [RustDeskSuspiciousEvent] {
        let since = status.now.addingTimeInterval(-7 * 86_400)
        let denied: [RustDeskDeniedAttempt]
        if RegEnvironment.isDemo {
            denied = RustDeskServerDemo.denied(now: status.now)
        } else {
            denied = LogStore.shared.recentForMonitoring(seconds: 7 * 86_400).compactMap { RustDeskDeniedAttempt.from($0) }
        }
        let requests = contents.history.isEmpty ? status.punchRequests.map(RustDeskArchivedRequest.init) : contents.history
        return RustDeskSuspicion.evaluate(requests: requests, known: Set(book.keys), denied: denied, since: since)
    }

    // MARK: Association à une fiche

    func proposeAssociation(id: String, targetIP: String) {
        associating = RustDeskAssociationRequest(id: id, targetIP: targetIP, candidates: [], searching: true)
        if RegEnvironment.isDemo {
            associating?.candidates = RustDeskServerDemo.candidates
            associating?.searching = false
            return
        }
        let host = (try? RustDeskServerModel.shared.resolvedAccount().get())?.host ?? ""
        let relays = RustDeskServerModel.shared.status?.relayServers ?? []
        Task {
            var serverIPs = Set<String>()
            for name in [host] + relays.map({ RustDeskRelaySession.split($0).ip }) where !name.isEmpty {
                if IPv4Address(name) != nil { serverIPs.insert(name) } else if let address = try? await PingResolver.resolveAsync(name) {
                    serverIPs.insert(address.description)
                }
            }
            let activeName = SiteModel.shared.activeName
            let store = InvModel.shared.store
            let devices = MonStore.shared.appState?.devices ?? []
            let candidates = RustDeskAssociation.candidates(
                targetIP: targetIP, serverIPs: serverIPs, wan: self.wanAddresses,
                sessions: TrafficStore.shared.monitorOverview?.sessions ?? []) { ip, site in
                    // Le site vient du WAN de la FortiGate : la fiche n'est cherchée que dans ce site
                    // (un autre site peut avoir les mêmes IP privées) ; la MAC trouvée l'identifie.
                    guard site == nil || site == activeName, let address = IPv4Address(ip) else { return nil }
                    if let record = store.record(forIP: address) {
                        return (record.mac?.formatted(.upperColon), record.displayName)
                    }
                    if let device = devices.first(where: { $0.ip == address }) {
                        return (device.mac?.formatted(.upperColon), device.hostnameLabel ?? ip)
                    }
                    return nil
                }
            guard self.associating?.id == id else { return }
            self.associating?.candidates = candidates
            self.associating?.searching = false
        }
    }

    var activeSiteName: String? {
        RegEnvironment.isDemo ? RustDeskServerDemo.activeSite : SiteModel.shared.activeName
    }

    /// Confirmé par l'utilisateur : l'ID va dans la fiche du site actif retrouvée par la MAC (jamais
    /// par l'IP seule). Sans MAC, ou candidat d'un autre site : refusé (simple indice).
    @discardableResult
    func associate(_ candidate: RustDeskAssociationCandidate, id: String) -> Bool {
        guard candidate.canAssociate(activeSite: activeSiteName), let text = candidate.mac, let mac = MACAddress(text),
              let record = InvModel.shared.store.record(InventoryStore.key(mac: mac)) else { return false }
        var annotations = record.annotations
        annotations.rustdeskID = RustDeskNames.key(id)
        InvModel.shared.setAnnotations(annotations, for: record.key)
        associating = nil
        return true
    }

    // MARK: Surveillance

    /// Ajoute à Surveillance la sonde du serveur (lecture SSH) et une sonde TCP par port surveillé.
    func addProbes() -> Int {
        guard let resolved = try? RustDeskServerModel.shared.resolvedAccount().get() else { return 0 }
        let account = resolved.label
        let host = resolved.host
        let monitor = MonStore.shared
        var added = 0
        // Paramètres non secrets du compte (clé, rebond, connexion du carnet) : l'agent lit comme l'app.
        func configure(_ probe: inout MonProbe) {
            probe.sshKeyPath = resolved.keyPath.isEmpty ? nil : resolved.keyPath
            probe.sshJump = resolved.jump.isEmpty ? nil : resolved.jump
            probe.sshConnection = RustDeskServerModel.shared.settings.connectionID
        }
        if var existing = monitor.probes.first(where: { $0.kind == .rustdeskServer && $0.target == account }) {
            let before = existing
            configure(&existing)
            if existing != before { monitor.save(existing) }
        } else {
            var probe = MonProbe(name: "Serveur RustDesk", kind: .rustdeskServer, target: account, interval: 300)
            configure(&probe)
            monitor.addProbe(probe)
            added += 1
        }
        // Sondes TCP lancées depuis ce Mac (réseau local ou VPN) : elles ne prouvent pas que le port
        // est joignable d'Internet (NAT, filtre géographique) ; le nom le dit.
        for port in contents.monitoredPorts {
            let target = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
            guard !monitor.probes.contains(where: { $0.kind == .tcp && $0.target == target }) else { continue }
            monitor.addProbe(MonProbe(name: "RustDesk \(port) (depuis ce Mac)", kind: .tcp, target: target, interval: 120))
            added += 1
        }
        return added
    }

    func setMonitoredPorts(_ text: String) {
        contents.monitoredPorts = RustDeskServerAlerts.ports(text)
        save()
    }

    // MARK: Rapport mensuel

    func report(year: Int, month: Int) -> RustDeskMonthlyReport {
        RustDeskMonthlyReport.build(contents.history, year: year, month: month,
                                    name: { self.name(for: $0) }, technician: { self.technicianName($0) })
    }

    func exportCSV(_ report: RustDeskMonthlyReport) {
        export(Data(report.csv().utf8), name: "rapport-rustdesk-\(report.year)-\(String(format: "%02d", report.month)).csv")
    }

    func exportPDF(_ report: RustDeskMonthlyReport) {
        export(RustDeskReportPDF.render(report), name: "rapport-rustdesk-\(report.year)-\(String(format: "%02d", report.month)).pdf")
    }

    private func export(_ data: Data, name: String) {
        guard !RegEnvironment.isSnapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("RustDesk", "Rapport non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }

    // MARK: Fichier

    /// Note 86 : suivi reçu d'un autre Mac.
    func reloadFromDisk() {
        guard let loaded = store?.load() else { return }
        let merged = RustDeskWatchStore.merge(local: contents, base: baseline, disk: loaded, now: Date())
        baseline = loaded
        if merged != contents { contents = merged }
    }

    /// Relit le fichier (peut-être écrit par un autre Mac) et fusionne avant d'écrire : rien de ce
    /// que l'autre Mac a écrit n'est perdu.
    private func save() {
        guard let store else { return }
        do {
            if let disk = store.load() {
                let merged = RustDeskWatchStore.merge(local: contents, base: baseline, disk: disk, now: Date())
                if merged != contents { contents = merged }
            }
            try store.save(contents)
            baseline = contents
        } catch {
            AppLog.shared.error("RustDesk", "Suivi du serveur non enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }
}

/// ID (nom et note) ou IP de technicien (nom) en cours de modification.
struct RustDeskNoteTarget: Identifiable, Equatable {
    enum Kind { case id, technician }
    var id: String { (kind == .id ? "id:" : "ip:") + key }
    var kind: Kind
    var key: String
}

/// Association proposée : candidats trouvés pour l'IP vue par hbbs.
struct RustDeskAssociationRequest: Identifiable, Equatable {
    var id: String
    var targetIP: String
    var candidates: [RustDeskAssociationCandidate]
    var searching: Bool
}
