import Foundation
import NetScopeCore
import SwiftUI

/// Échec d'un test planifié.
enum SpeedPlannedFailure: Error, Equatable {
    /// Arrêté, ou remplacé par un test lancé à la main.
    case interrupted
    case failed(String)

    var message: String {
        switch self {
        case .interrupted: return "test interrompu"
        case .failed(let text): return text
        }
    }
}

/// Test planifié en cours : site, et suite à donner au résultat.
struct SpeedPlannedRun {
    let siteID: UUID?
    let siteName: String?
    let completion: @MainActor (Result<SpeedTestRecord, SpeedPlannedFailure>) -> Void
}

extension SpeedtestModel {
    /// Lance le test Internet pour la planification (serveur choisi dans Serveurs, ou automatique) :
    /// la jauge de l'onglet Internet le montre comme un test ordinaire ; le résultat entre dans
    /// l'historique avec l'origine « planifié » et le site.
    func runPlanned(siteID: UUID?, siteName: String?, interface: LocalInterface?,
                    completion: @escaping @MainActor (Result<SpeedTestRecord, SpeedPlannedFailure>) -> Void) {
        startInternet(interface: interface)
        plannedRun = SpeedPlannedRun(siteID: siteID, siteName: siteName, completion: completion)
    }

    /// Termine le test planifié en cours (une seule fois).
    func finishPlanned(_ result: Result<SpeedTestRecord, SpeedPlannedFailure>) {
        guard let run = plannedRun else { return }
        plannedRun = nil
        run.completion(result)
    }
}

/// Note 78 (Speedtest) : sonde « débit Internet » planifiée, une fois par jour à l'heure choisie,
/// réglée site par site (speedtest-planifie.json). Toutes les minutes, le réglage du site actif
/// est examiné par `SpeedSchedulePlanner` ; le test est reporté pendant un scan, pendant un autre
/// test et sur une connexion absente ou limitée, et rattrapé dans la journée. Sous le seuil, une
/// notification « Débit Internet sous le seuil » part par le centre de notifications.
/// En démonstration et pendant les captures, aucun test n'est lancé (historique fictif).
@MainActor
final class SpeedScheduleStore: ObservableObject {
    static let shared = SpeedScheduleStore()

    @Published private(set) var book: SpeedScheduleBook
    /// Site affiché dans la courbe et l'éditeur ; nil : site actif.
    @Published var selectedKey: String?
    /// Site dont le test planifié tourne.
    @Published private(set) var runningKey: String?
    @Published var message: (text: String, tone: Tone)?

    let isEphemeral: Bool
    private let file: SpeedScheduleFile?
    private var timer: Timer?
    private weak var state: AppState?

    private init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        if isEphemeral {
            file = nil
            book = arguments.contains("--demo") ? SpeedScheduleDemo.book() : SpeedScheduleBook()
            if let raw = ProcessInfo.processInfo.environment["NETSCOPE_DEBIT_SITE"],
               let site = SiteModel.shared.list.sites.first(where: { $0.displayName == raw }) {
                selectedKey = SpeedSchedule.key(for: site.id)
            }
        } else {
            let file = SpeedScheduleFile.standard
            self.file = file
            book = file.load()
        }
    }

    // MARK: Lancement

    /// Premier passage une minute après le lancement, puis toutes les minutes.
    func attach(to state: AppState) {
        self.state = state
        guard !isEphemeral, timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await SpeedScheduleStore.shared.tick() }
        }
        timer.fireDate = Date().addingTimeInterval(60)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() async {
        guard !isEphemeral, runningKey == nil, let state else { return }
        let siteID = SiteModel.shared.activeID
        let schedule = book.schedule(for: siteID)
        guard SpeedSchedulePlanner.isDue(schedule, now: Date()) else { return }
        let path = await NetworkPathStatus.current()
        let model = SpeedtestModel.shared
        if let blocker = SpeedSchedulePlanner.blocker(isScanning: ScanController.shared.isRunning,
                                                      testRunning: model.runState.isRunning || model.lanRunning, path: path) {
            let status = SpeedScheduleStatus.postponed(blocker.label)
            if schedule.lastStatus != status {
                var updated = schedule
                updated.lastStatus = status
                book.set(updated)
                save()
                AppLog.shared.info("Speedtest", "Test planifié reporté\u{00A0}: \(blocker.label).")
            }
            return
        }
        run(siteID: siteID, interface: state.activeInterface)
    }

    /// Lance le test planifié du site actif (échéance, ou « Lancer maintenant »).
    func run(siteID: UUID?, interface: LocalInterface?) {
        guard runningKey == nil, !isEphemeral else { return }
        let model = SpeedtestModel.shared
        guard !model.runState.isRunning, !model.lanRunning else {
            show("Un test de débit est déjà en cours.", tone: .warning)
            return
        }
        let key = SpeedSchedule.key(for: siteID)
        let name = siteName(siteID)
        runningKey = key
        AppLog.shared.info("Speedtest", "Test de débit planifié lancé pour «\u{00A0}\(name)\u{00A0}».")
        model.runPlanned(siteID: siteID, siteName: name, interface: interface) { result in
            SpeedScheduleStore.shared.finish(siteID: siteID, name: name, result: result)
        }
    }

    private func finish(siteID: UUID?, name: String, result: Result<SpeedTestRecord, SpeedPlannedFailure>) {
        runningKey = nil
        var schedule = book.schedule(for: siteID)
        schedule.lastRun = Date()
        switch result {
        case .success(let record):
            let verdict = SpeedSchedulePlanner.verdict(downMbps: record.downMbps, upMbps: record.upMbps, schedule: schedule)
            schedule.lastStatus = verdict.isBelow ? .below(downMbps: record.downMbps, upMbps: record.upMbps)
                                                  : .ok(downMbps: record.downMbps, upMbps: record.upMbps)
            if verdict.isBelow {
                let text = SpeedSchedulePlanner.alertText(siteName: name, downMbps: record.downMbps, upMbps: record.upMbps,
                                                          schedule: schedule)
                AppLog.shared.warning("Speedtest", "\(text.title). \(text.detail)")
                NetScopeEventCenter.shared.publish(NetScopeEvent(
                    id: "debit-planifie-\(schedule.id)-\(Int(record.date.timeIntervalSince1970))", kind: .internetSpeedLow,
                    title: text.title, detail: text.detail, date: record.date,
                    link: .screen(MonNotifier.speedScheduleLink), source: "debit-planifie-" + schedule.id))
            }
        case .failure(let failure):
            schedule.lastStatus = .failed(failure.message)
            AppLog.shared.warning("Speedtest", "Test de débit planifié en échec pour «\u{00A0}\(name)\u{00A0}»\u{00A0}: \(failure.message).")
        }
        book.set(schedule)
        save()
    }

    // MARK: Réglages

    /// Sites proposés : tous les sites, ou « Ce Mac » s'il n'y en a aucun.
    var sites: [(key: String, id: UUID?, name: String)] {
        let list = SiteModel.shared.list.sortedByName
        if list.isEmpty { return [(SpeedSchedule.key(for: nil), nil, siteName(nil))] }
        return list.map { (SpeedSchedule.key(for: $0.id), $0.id, $0.displayName) }
    }

    var activeKey: String { SpeedSchedule.key(for: SiteModel.shared.activeID) }

    /// Site affiché (choisi dans le tableau, sinon le site actif).
    var selected: (key: String, id: UUID?, name: String) {
        let all = sites
        return all.first { $0.key == (selectedKey ?? activeKey) } ?? all.first { $0.key == activeKey } ?? all[0]
    }

    func schedule(for siteID: UUID?) -> SpeedSchedule { book.schedule(for: siteID) }

    func siteName(_ siteID: UUID?) -> String {
        guard let siteID else { return "Ce Mac" }
        return SiteModel.shared.list.sites.first { $0.id == siteID }?.displayName ?? "Site supprimé"
    }

    /// Modifie le réglage d'un site. Activer ou changer l'heure « arme » la planification : une
    /// échéance déjà passée aujourd'hui n'est pas rattrapée.
    func update(_ siteID: UUID?, _ change: (inout SpeedSchedule) -> Void) {
        var schedule = book.schedule(for: siteID)
        let before = schedule
        change(&schedule)
        if schedule.isEnabled && (!before.isEnabled || schedule.time != before.time) { schedule.armedAt = Date() }
        guard schedule != before else { return }
        book.set(schedule)
        save()
    }

    private func save() {
        guard let file else { return }
        do {
            try file.save(book)
        } catch {
            AppLog.shared.error("Speedtest", "Enregistrement des tests planifiés impossible\u{00A0}: \(error.localizedDescription)")
        }
    }

    private func show(_ text: String, tone: Tone) {
        message = (text, tone)
    }
}
