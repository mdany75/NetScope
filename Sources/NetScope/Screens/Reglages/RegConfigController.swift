import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Note 56 : « Exporter la configuration… » et « Importer la configuration… » (Réglages › Export et
/// sauvegarde). Un seul fichier .netscope-config ; toutes les parties cochées par défaut, chacune
/// décochable ; mot de passe obligatoire dès qu'un jeton ou un secret est inclus.
///
/// L'import montre d'abord un aperçu (ajouté, remplacé, identique, conflit). Une fois confirmé :
/// sauvegarde de sécurité de l'état actuel, secrets remis au Trousseau de ce Mac, puis le reste est
/// appliqué au lancement suivant (avant que les écrans ne lisent leurs fichiers), comme une
/// restauration. En démonstration et pendant les captures, rien n'est lu ni écrit.
@MainActor
final class RegConfigController: ObservableObject {
    static let shared = RegConfigController()

    enum Key {
        /// Bilan du dernier import appliqué au lancement (lu une fois).
        static let report = "configuration.bilanImport"
    }

    /// Import en attente du redémarrage (dossier caché : jamais sauvegardé ni exporté).
    nonisolated static var pendingURL: URL {
        RegBackupController.dataDirectory.appendingPathComponent(".configuration", isDirectory: true).appendingPathComponent("import-en-attente.json")
    }

    /// Feuille d'export ouverte.
    @Published var exporting = false
    /// Contenu de ce Mac, partie par partie (feuille d'export).
    @Published private(set) var contents: [ConfigPartContents] = []
    /// Fichier choisi pour l'import, chiffré : feuille du mot de passe.
    @Published var unlockRequest: URL?
    /// Aperçu de l'import.
    @Published var preview: ConfigImportPlan?
    @Published private(set) var isWorking = false
    @Published var message: (text: String, tone: Tone)?

    /// État local utilisé pour l'aperçu (comparaison et empreintes attendues).
    private var previewLocal = ConfigSnapshot()

    var registry: ConfigPartRegistry { .standard }

    // MARK: État de ce Mac

    /// Préférences de l'app (domaine persistant).
    nonisolated static func currentPreferences() -> [String: Any] {
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.persistentDomain(forName: RegBackupController.preferencesDomain) ?? [:]
    }

    /// Comptes du Trousseau (noms et usages lisibles, sans lire les valeurs).
    nonisolated static func secretNames() -> [BackupKeychainItem] {
        BackupKeychainScan.describe(BackupKeychainScan.items(), fortiGates: FortiGateStore.savedControllers())
    }

    /// État de ce Mac ; les valeurs des secrets ne sont lues que si `withSecrets` (export).
    nonisolated static func snapshot(withSecrets: Bool) -> ConfigSnapshot {
        let names = secretNames()
        var secrets: [BackupSecret] = []
        if withSecrets {
            let usages = Dictionary(names.map { ($0.service + "|" + $0.account, $0.usage) }, uniquingKeysWith: { a, _ in a })
            secrets = ((try? BackupKeychainSecrets().readSecrets()) ?? []).map { secret in
                var copy = secret
                copy.usage = usages[secret.service + "|" + secret.account] ?? secret.usage
                return copy
            }
        }
        return ConfigSnapshot.read(dataDirectory: RegBackupController.dataDirectory, preferences: currentPreferences(),
                                   secrets: secrets, secretNames: names)
    }

    nonisolated static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Écrit d'abord ce qui est en mémoire : l'export et l'aperçu voient l'état actuel.
    private func flushStores() {
        MonStore.shared.save()
        InvModel.shared.flushPendingWrites()
    }

    // MARK: Export

    func beginExport() {
        if RegEnvironment.isSandboxed {
            contents = ConfigSyncDemo.exportContents()
            exporting = true
            return
        }
        flushStores()
        Task {
            contents = await Task.detached { ConfigArchive.contents(of: Self.snapshot(withSecrets: false)) }.value
            exporting = true
        }
    }

    /// Vrai si les parties choisies contiennent un secret (mot de passe obligatoire).
    func includesSecrets(_ parts: Set<String>) -> Bool {
        contents.contains { parts.contains($0.id) && !$0.secrets.isEmpty }
    }

    /// Export confirmé : emplacement choisi, puis fichier écrit (secrets lus au Trousseau seulement
    /// si une partie à secrets est cochée).
    func export(parts: Set<String>, password: String?) {
        exporting = false
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: aucun fichier n’est écrit.", .neutral)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Exporter la configuration"
        panel.prompt = "Exporter"
        panel.nameFieldStringValue = ConfigArchive.suggestedName(for: Date())
        panel.allowedContentTypes = [UTType(filenameExtension: ConfigArchive.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let withSecrets = includesSecrets(parts)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        isWorking = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result {
                    try ConfigArchive.export(Self.snapshot(withSecrets: withSecrets), parts: parts, password: password,
                                             deviceName: Self.deviceName, appVersion: version, appBuild: build)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let data):
                do {
                    try data.write(to: url, options: .atomic)
                    let detail = password == nil ? "non chiffré, sans secret" : (withSecrets ? "chiffré, avec les jetons et secrets" : "chiffré")
                    message = ("Configuration exportée (\(detail))\u{00A0}: \(url.lastPathComponent).", .success)
                } catch {
                    message = ("Export impossible\u{00A0}: \(error.localizedDescription)", .critical)
                }
            case .failure(let error):
                message = ("Export impossible\u{00A0}: \(error.localizedDescription)", .critical)
            }
        }
    }

    // MARK: Import

    func beginImport() {
        if RegEnvironment.isSandboxed {
            previewLocal = ConfigSyncDemo.localSnapshot()
            preview = ConfigSyncDemo.importPlan()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Importer la configuration"
        panel.prompt = "Choisir"
        panel.message = "Une configuration exportée (.netscope-config) ou une sauvegarde de NetScope."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: ConfigArchive.fileExtension) ?? .data, .zip, .folder,
                                     UTType(filenameExtension: BackupEngine.encryptedExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if BackupCrypto.isEncryptedFile(url) {
            unlockRequest = url
        } else {
            openFile(url)
        }
    }

    /// Lit le fichier (mot de passe vérifié hors du fil principal) puis prépare l'aperçu.
    /// Renvoie l'erreur à montrer dans la feuille du mot de passe.
    @discardableResult
    func open(_ url: URL, password: String?) async -> String? {
        if RegEnvironment.isSandboxed {
            guard password == ReglagesDemo.demoPassword else { return BackupCryptoError.wrongPassword.localizedDescription }
            await closeUnlockSheet()
            previewLocal = ConfigSyncDemo.localSnapshot()
            preview = ConfigSyncDemo.importPlan()
            return nil
        }
        flushStores()
        isWorking = true
        defer { isWorking = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(ConfigImportPlan, ConfigSnapshot), Error> in
            Result {
                let package = try ConfigArchive.read(url, password: password)
                let local = Self.snapshot(withSecrets: false)
                return (ConfigImporter.plan(package, local: local), local)
            }
        }.value
        switch result {
        case .success(let (plan, local)):
            await closeUnlockSheet()
            previewLocal = local
            preview = plan
            return nil
        case .failure(let error):
            if password == nil { message = (error.localizedDescription, .critical) }
            return error.localizedDescription
        }
    }

    /// Ferme la feuille du mot de passe et laisse finir son animation : la feuille de l'aperçu
    /// s'ouvre ensuite (SwiftUI ne montre pas deux feuilles à la fois).
    private func closeUnlockSheet() async {
        guard unlockRequest != nil else { return }
        unlockRequest = nil
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func openFile(_ url: URL) {
        Task { await open(url, password: nil) }
    }

    /// Import confirmé : sauvegarde de sécurité, secrets au Trousseau, le reste au redémarrage.
    func confirmImport(selected: Set<String>, parts: Set<String>) {
        guard let plan = preview else { return }
        preview = nil
        if RegEnvironment.isSandboxed {
            message = ("Démonstration\u{00A0}: rien n’est importé, le Trousseau n’est pas modifié.", .neutral)
            return
        }
        let apply = ConfigImporter.resolve(plan, selected: selected, parts: parts, local: previewLocal)
        guard !apply.isEmpty else {
            message = ("Rien à importer\u{00A0}: tout est déjà identique sur ce Mac.", .neutral)
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            guard await RegBackupController.shared.safetyBackup() != nil else {
                message = ("Import annulé\u{00A0}: la sauvegarde de sécurité de l’état actuel a échoué.", .critical)
                return
            }
            var failed: [BackupKeychainItem] = []
            if !apply.secrets.isEmpty {
                let secrets = apply.secrets
                failed = await Task.detached { BackupEngine.restoreSecrets(secrets, to: BackupKeychainSecrets()) }.value
            }
            let pending = apply.withoutSecrets
            if pending.isEmpty {
                message = failed.isEmpty
                    ? ("Configuration importée\u{00A0}: " + MonText.plural(apply.secrets.count, "secret remis", "secrets remis") + " au Trousseau.", .success)
                    : ("\(failed.count) secret\(failed.count > 1 ? "s" : "") non remis au Trousseau\u{00A0}: " + failed.map(\.usage).joined(separator: ", "), .warning)
                return
            }
            do {
                try Self.savePending(pending, secretsRestored: apply.secrets.count - failed.count)
            } catch {
                message = ("Import annulé\u{00A0}: \(error.localizedDescription)", .critical)
                return
            }
            if !failed.isEmpty {
                message = ("\(failed.count) secret\(failed.count > 1 ? "s" : "") non remis au Trousseau\u{00A0}: " + failed.map(\.usage).joined(separator: ", ")
                           + ". Le reste de l’import sera appliqué au prochain lancement.", .warning)
                return
            }
            if UpdInstaller.runningBundle() == nil {
                message = ("Import prêt\u{00A0}: quittez NetScope et rouvrez-le pour l’appliquer.", .warning)
            }
            RegBackupController.shared.relaunch()
        }
    }

    func cancelImport() {
        preview = nil
        previewLocal = ConfigSnapshot()
    }

    // MARK: Application au lancement

    struct Pending: Codable {
        var plan: ConfigApplyPlan
        var secretsRestored: Int
    }

    nonisolated static func savePending(_ plan: ConfigApplyPlan, secretsRestored: Int, to url: URL = pendingURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupEngine.encoder().encode(Pending(plan: plan.withoutSecrets, secretsRestored: secretsRestored)).write(to: url, options: .atomic)
    }

    /// Au lancement, avant les écrans : applique un import (ou des changements synchronisés) en attente.
    nonisolated static func applyPending(at url: URL = pendingURL, reportKey: String = Key.report) {
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let pending = try? BackupEngine.decoder().decode(Pending.self, from: data) else { return }
        let defaults = UserDefaults.standard
        let outcome = ConfigImporter.apply(pending.plan, to: RegBackupController.dataDirectory, preferences: currentPreferences())
        for (key, value) in outcome.preferences {
            if let decoded = ConfigPlist.decode(value) { defaults.set(decoded, forKey: key) }
        }
        var text = pending.plan.origin == "synchro" ? "Changements reçus appliqués\u{00A0}: " : "Configuration importée\u{00A0}: "
        text += MonText.plural(outcome.applied.count, "élément", "éléments")
        if pending.secretsRestored > 0 { text += ", " + MonText.plural(pending.secretsRestored, "secret remis", "secrets remis") + " au Trousseau" }
        text += "."
        if !outcome.skipped.isEmpty {
            text += " Laissés tels quels (modifiés sur ce Mac entre-temps)\u{00A0}: " + outcome.skipped.joined(separator: ", ") + "."
        }
        if !outcome.failed.isEmpty { text += " Échecs\u{00A0}: " + outcome.failed.joined(separator: ", ") + "." }
        defaults.set(text, forKey: reportKey)
        defaults.synchronize()
    }

    /// Bilan laissé par l'application au lancement, lu une fois.
    func takeReport() {
        guard !RegEnvironment.isSandboxed, let text = UserDefaults.standard.string(forKey: Key.report) else { return }
        UserDefaults.standard.removeObject(forKey: Key.report)
        message = (text, text.contains("Échecs") ? .warning : .success)
    }
}
