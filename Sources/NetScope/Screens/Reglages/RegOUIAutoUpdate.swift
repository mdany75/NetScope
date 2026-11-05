import Foundation
import NetScopeCore
import SwiftUI

/// Note 81 : mise à jour automatique de la base des fabricants (registre IEEE).
///
/// Au lancement (après 2 minutes), puis toutes les 6 heures, `OUIAutoUpdatePolicy` décide s'il
/// faut vérifier : option activée, base de plus de 30 jours, au plus une fois par mois, ni scan
/// en cours, ni connexion limitée (NWPathMonitor). Le téléchargement réutilise `OUIUpdater` :
/// mêmes vérifications que la mise à jour manuelle, écriture atomique, ancienne base gardée si
/// quelque chose échoue. Une base remplacée donne une notification discrète (« +312 préfixes »).
/// En démonstration et pendant les captures, rien n'est lu, écrit ni téléchargé.
@MainActor
final class OUIAutoController: ObservableObject {
    static let shared = OUIAutoController()

    static let defaultsKey = "NetScope.oui.miseAJourAuto"

    @Published private(set) var settings: OUIAutoUpdateSettings
    /// Dernière décision (« Reportée : scan en cours. ») ; nil avant le premier passage.
    @Published private(set) var lastSkip: OUIAutoUpdateSkip?
    @Published private(set) var isChecking = false

    private let defaults: UserDefaults?
    private var timer: Timer?
    private var task: Task<Void, Never>?

    private init() {
        if RegEnvironment.isSandboxed {
            defaults = nil
            settings = OUIAutoDemo.settings
        } else {
            defaults = UserDefaults.standard
            settings = OUIAutoUpdateSettings.decode(UserDefaults.standard.data(forKey: Self.defaultsKey))
        }
    }

    /// Lance la vérification périodique (jamais en démonstration ni pendant les captures).
    func start() {
        guard !RegEnvironment.isSandboxed, timer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3_600, repeats: true) { _ in
            Task { @MainActor in OUIAutoController.shared.tick() }
        }
        // Premier passage 2 minutes après le lancement : la fenêtre, les sites et un éventuel
        // scan automatique ont démarré, et le lancement reste léger.
        timer.fireDate = Date().addingTimeInterval(120)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if !enabled {
            task?.cancel()
            lastSkip = .disabled
        } else {
            lastSkip = nil
        }
        save()
    }

    /// Démonstration : la dernière vérification fictive a produit la base chargée (même jour).
    func alignDemo(to date: Date?) {
        guard RegEnvironment.isDemo, let date else { return }
        let checked = date.addingTimeInterval(98 * 60)
        guard settings.lastCheck != checked else { return }
        settings.lastCheck = checked
        settings.lastUpdate = checked
    }

    /// Date de la base en place (en-tête du fichier).
    var databaseDate: Date? { OUIAutoUpdatePolicy.databaseDate(OUIController.shared.source?.date) }

    /// Prochaine vérification permise (nil : dès que possible, ou option désactivée).
    var nextCheck: Date? {
        guard settings.isEnabled else { return nil }
        return OUIAutoUpdatePolicy.nextCheck(settings, databaseDate: databaseDate)
    }

    private func tick() {
        guard !isChecking, !RegEnvironment.isSandboxed else { return }
        // La mise à jour manuelle en cours a la priorité.
        guard !OUIController.shared.isWorking else { return }
        task = Task { [weak self] in
            // Provenance lue hors du fil principal (le premier accès charge la base).
            let header = await Task.detached(priority: .utility) { OUIDatabase.builtIn.source.date }.value
            let path = await NetworkPathStatus.current()
            guard let self, !Task.isCancelled else { return }
            let context = OUIAutoUpdateContext(now: Date(), databaseDate: OUIAutoUpdatePolicy.databaseDate(header),
                                               isScanning: ScanController.shared.isRunning, path: path,
                                               isSandboxed: RegEnvironment.isSandboxed)
            switch OUIAutoUpdatePolicy.decide(self.settings, context: context) {
            case .skip(let reason):
                self.lastSkip = reason
                if reason.isPostponed { AppLog.shared.info("Base des fabricants", "Vérification automatique \(reason.label.lowercased())") }
            case .check:
                await self.check()
            }
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        lastSkip = nil
        AppLog.shared.info("Base des fabricants", "Vérification automatique du registre IEEE.")
        let updater = OUIUpdater()
        let result = await Task.detached(priority: .utility) { [settings] in
            await OUIAutoUpdateRun.perform(settings: settings, updater: updater, database: .builtIn) {
                try await updater.download()
            }
        }.value
        guard let result else { return }
        settings = result.settings
        save()
        OUIController.shared.refresh()
        MonWindow.appState?.objectWillChange.send()
        switch result.outcome {
        case .updated:
            AppLog.shared.info("Base des fabricants", "Mise à jour automatique\u{00A0}: \(result.outcome.label).")
            if let text = OUIAutoUpdateRun.notificationText(result.outcome) {
                NetScopeEventCenter.shared.publish(NetScopeEvent(
                    id: "oui-auto-\(Int(Date().timeIntervalSince1970))", kind: .ouiUpdated, title: text.title,
                    detail: text.detail, link: .screen(MonNotifier.ouiSettingsLink), source: "base-des-fabricants"))
            }
        case .failed(let message):
            AppLog.shared.warning("Base des fabricants", "Mise à jour automatique en échec (ancienne base gardée)\u{00A0}: \(message)")
        }
    }

    private func save() {
        guard let defaults, let data = settings.encoded() else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Encadré « Mise à jour automatique » de Réglages › Base des fabricants.
struct RegOUIAutoBox: View {
    @ObservedObject private var auto = OUIAutoController.shared
    @ObservedObject private var controller = OUIController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RegToggleRow(title: "Mettre à jour automatiquement",
                         detail: "Au plus une fois par mois, quand la base a plus de 30\u{00A0}jours\u{00A0}: jamais pendant un scan ni sur une connexion limitée (partage de connexion du téléphone, données réduites). En cas d’échec, la base en place est gardée.",
                         isOn: Binding(get: { auto.settings.isEnabled }, set: { auto.setEnabled($0) }),
                         isEnabled: !RegEnvironment.isSandboxed || RegEnvironment.isDemo)
            RegTileRow {
                RegTile("Date de la base", baseDateText)
                RegTile("Dernière vérification", lastCheckText)
                RegTile("Préfixes ajoutés", addedText)
                RegTile("Prochaine vérification", nextText)
            }
            if let status = statusText {
                Text(status.text)
                    .font(Theme.small)
                    .foregroundStyle(status.tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Démonstration : la dernière vérification fictive suit la date de la base chargée.
        .onAppear { auto.alignDemo(to: auto.databaseDate) }
        .onChange(of: controller.source) { auto.alignDemo(to: auto.databaseDate) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy 'à' HH:mm"
        return formatter
    }()

    private var baseDateText: String {
        guard let date = auto.databaseDate else { return controller.source == nil ? "Chargement…" : "Inconnue" }
        let days = max(0, Int(Date().timeIntervalSince(date) / 86_400))
        let age = days == 0 ? "aujourd’hui" : (days == 1 ? "il y a 1 jour" : "il y a \(days) jours")
        return "\(Self.dayFormatter.string(from: date)) (\(age))"
    }

    private var lastCheckText: String {
        auto.settings.lastCheck.map { Self.dayTimeFormatter.string(from: $0) } ?? "Jamais"
    }

    private var addedText: String {
        switch auto.settings.lastOutcome {
        case .updated(let added, _)?: return added > 0 ? "+\(added.formatted(.number.locale(Locale(identifier: "fr_CA"))))" : "Aucun"
        case .failed?: return "Échec (base gardée)"
        case nil: return "—"
        }
    }

    private var nextText: String {
        guard auto.settings.isEnabled else { return "Désactivée" }
        if auto.isChecking { return "En cours…" }
        guard let next = auto.nextCheck, next > Date() else { return "Dès que possible" }
        return Self.dayFormatter.string(from: next)
    }

    private var statusText: (text: String, tone: Tone)? {
        if case .failed(let message)? = auto.settings.lastOutcome {
            return ("Dernière vérification en échec\u{00A0}: \(message) La base en place a été gardée\u{00A0}; nouvel essai demain.", .warning)
        }
        if let skip = auto.lastSkip, skip.isPostponed { return ("Vérification \(skip.label.lowercased())", .neutral) }
        return nil
    }
}
