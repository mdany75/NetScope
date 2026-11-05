import AppKit
import Foundation
import NetScopeCore

/// Note 42 : rapports planifiés. Une seule instance, lancée avec l'app (fenêtre fermée comprise) :
/// toutes les 30 secondes, elle regarde si une échéance est passée et produit au plus UN rapport
/// planifié, avec un écart minimal entre deux productions (rattrapage au lancement sans rafale).
/// Jamais pendant un scan ; jamais de scan lancé ; aucun courriel sans choix explicite : un brouillon
/// dans Mail, ou (note 78) l'envoi SMTP choisi pour CE rapport. Enregistré dans rapports/planifies.json. En démonstration, deux
/// rapports planifiés fictifs, rien ne s'exécute ni ne s'écrit.
@MainActor
final class RapportScheduleStore: ObservableObject {
    static let shared = RapportScheduleStore()

    @Published private(set) var book: ReportScheduleBook
    /// Rapport planifié en cours de modification (nouveau compris) ; nil : aucun éditeur ouvert.
    @Published var draft: ReportSchedule?
    @Published private(set) var producing: UUID?
    /// Note 78 : rapport planifié dont le courriel part en ce moment.
    @Published private(set) var sending: UUID?
    @Published var message: (text: String, tone: Tone)?

    let isDemo: Bool
    /// Date figée de la démonstration (libellés stables dans les captures).
    let demoNow: Date?
    private var timer: Timer?
    private weak var state: AppState?
    private var lastProduction: Date?
    private var messageTask: Task<Void, Never>?

    private var directory: URL { RapportModel.shared.directory }

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        if demo {
            demoNow = RapportSuiviDemo.now
            book = ReportScheduleBook(schedules: RapportSuiviDemo.schedules)
            // Captures : NETSCOPE_RAPPORT_PLANIF=edition ouvre l'éditeur du premier rapport planifié.
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_PLANIF"] == "edition" { draft = book.schedules.first }
        } else {
            demoNow = nil
            book = ReportScheduleBook.load(from: ReportLibrary.defaultDirectory)
        }
    }

    var now: Date { demoNow ?? Date() }
    var schedules: [ReportSchedule] { book.schedules }
    let calendar = ReportScheduler.calendar()

    // MARK: Lancement

    /// Au lancement : premier passage après 20 secondes (sites et dernier scan rechargés), puis toutes les 30 s.
    func attach(to state: AppState) {
        self.state = state
        guard !isDemo, timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in RapportScheduleStore.shared.tick() }
        }
        timer.fireDate = Date().addingTimeInterval(20)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isDemo, producing == nil, state != nil else { return }
        // Pendant un scan, les appareils du site actif sont incomplets : on attend la fin.
        guard !ScanController.shared.isRunning else { return }
        let now = Date()
        guard ReportScheduler.canProduce(lastProduction: lastProduction, now: now),
              let next = ReportScheduler.pending(book.schedules, now: now, calendar: calendar).first else { return }
        produce(next.id, slot: next.slot, now: now)
    }

    // MARK: Production

    /// Produit le rapport planifié pour l'échéance donnée (ou « maintenant »), un fichier par site.
    /// Note 78 : `testMail` (« Envoyer un essai ») envoie le résultat même si l'envoi automatique
    /// n'est pas activé ; sinon il ne part que si « Envoyer par courriel » est choisi.
    private func produce(_ id: UUID, slot: Date?, now: Date, testMail: Bool = false) {
        guard let index = book.schedules.firstIndex(where: { $0.id == id }), let state else { return }
        let schedule = book.schedules[index]
        producing = id
        lastProduction = now
        defer { producing = nil }

        var files: [URL] = []
        var produced: [(key: String, url: URL)] = []
        var errors: [String] = []
        for key in schedule.siteKeys {
            switch RapportModel.shared.produceScheduled(schedule, siteKey: key, slot: slot ?? now, state: state, now: now) {
            case .success(let url):
                files.append(url)
                produced.append((key, url))
            case .failure(let error): errors.append("\(SiteModel.shared.name(forKey: key))\u{00A0}: \(error.message)")
            }
        }
        // Note 78 : envoi par le serveur SMTP des Alertes, seulement s'il a été choisi (ou pour l'essai).
        if (schedule.email == .send || testMail), !produced.isEmpty {
            mail(schedule, files: produced, isTest: testMail, now: now)
        }
        var updated = schedule
        if let slot { updated.lastSlot = slot }
        updated.lastProduced = now
        updated.lastFiles = files.map(\.lastPathComponent)
        updated.lastStatus = errors.isEmpty ? .ok : (files.isEmpty ? .failed : .partial)
        let catchUp = slot.map { ReportScheduler.isCatchUp(slot: $0, now: now) } ?? false
        var text = files.count > 1 ? "\(files.count) rapports produits" : (files.count == 1 ? "Rapport produit" : "Aucun rapport produit")
        if catchUp { text += " (échéance du \(ReportScheduler.dateLabel(slot!, now: now, calendar: calendar)) rattrapée)" }
        if !errors.isEmpty { text += ". Échec\u{00A0}: " + errors.joined(separator: "\u{00A0}; ") }
        updated.lastMessage = text + "."
        book.schedules[index] = updated
        save()

        let folderName = schedule.folder.map { ($0 as NSString).lastPathComponent } ?? "Application Support/NetScope/rapports"
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            kind: .reportReady, severity: errors.isEmpty ? .info : .warning,
            title: (errors.isEmpty ? "Rapport planifié prêt\u{00A0}: "
                    : (files.isEmpty ? "Rapport planifié en échec\u{00A0}: " : "Rapport planifié incomplet\u{00A0}: ")) + schedule.name,
            detail: files.isEmpty ? text + "." : text + " dans «\u{00A0}\(folderName)\u{00A0}»\u{00A0}: "
                + files.map(\.lastPathComponent).joined(separator: ", ") + ".",
            link: .screen(Screen.rapports.rawValue), source: "rapport-planifie-" + schedule.id.uuidString))

        // Courriel : jamais envoyé ; au mieux un brouillon à relire dans Mail.
        if schedule.email == .draft, !files.isEmpty {
            let day = ReportText.longDate(ReportText.isoDay(now)) ?? ReportText.isoDay(now)
            let subject = schedule.name + " — " + day
            let body = "Bonjour,\n\nVous trouverez ci-joint le rapport «\u{00A0}\(schedule.name)\u{00A0}» du \(day).\n\n"
            if !RapportModel.shared.openDraft(to: schedule.emailTo, subject: subject, body: body, files: files) {
                show("Aucune app de courriel configurée\u{00A0}: le rapport est dans son dossier.", tone: .warning)
            }
        }
        show(updated.lastMessage ?? text, tone: errors.isEmpty ? .success : .warning)
    }

    // MARK: Envoi par courriel (note 78)

    /// Envoie chaque fichier aux destinataires de son site, l'un après l'autre ; le résultat est
    /// ajouté au dernier message du rapport planifié et au journal des Alertes. Jamais en démonstration.
    private func mail(_ schedule: ReportSchedule, files: [(key: String, url: URL)], isTest: Bool, now: Date) {
        guard !isDemo else { return }
        sending = schedule.id
        // Mot de passe SMTP : présence relue au Trousseau juste avant l'envoi.
        AlertDispatcher.shared.refreshSecrets()
        Task { @MainActor in
            var notes: [String] = []
            var failed = false
            for file in files {
                let site = SiteModel.shared.name(forKey: file.key)
                let problems = AlertDispatcher.shared.reportProblems(schedule, siteKey: file.key, siteName: site)
                guard problems.isEmpty else {
                    notes.append("\(site)\u{00A0}: courriel non envoyé, " + problems.joined(separator: " ").lowercasedFirst)
                    failed = true
                    continue
                }
                guard let data = try? Data(contentsOf: file.url), data.count <= ReportMail.maxAttachmentBytes else {
                    notes.append("\(site)\u{00A0}: courriel non envoyé, fichier illisible ou trop gros pour un courriel")
                    failed = true
                    continue
                }
                let message = ReportMail.message(scheduleName: schedule.name, siteName: site, fileName: file.url.lastPathComponent,
                                                 data: data, recipients: ReportMail.recipients(schedule, siteKey: file.key),
                                                 smtp: AlertDispatcher.shared.settings.smtp, date: now, isTest: isTest,
                                                 mailer: "NetScope \(AppInfo.version)", calendar: calendar)
                let result = await AlertDispatcher.shared.sendReport(message, title: (isTest ? "Essai\u{00A0}: " : "") + schedule.name + " — " + site,
                                                                     isTest: isTest)
                notes.append("\(site)\u{00A0}: " + (result.ok ? "courriel " + result.detail : "échec du courriel, " + result.detail.lowercasedFirst))
                if !result.ok { failed = true }
            }
            sending = nil
            let text = (isTest ? "Essai\u{00A0}: " : "") + notes.joined(separator: "\u{00A0}; ")
            if let index = book.schedules.firstIndex(where: { $0.id == schedule.id }) {
                let base = book.schedules[index].lastMessage ?? ""
                book.schedules[index].lastMessage = (base.hasSuffix(".") ? String(base.dropLast()) : base) + ". " + text + "."
                if failed, book.schedules[index].lastStatus == .ok { book.schedules[index].lastStatus = .partial }
                save()
            }
            if failed {
                NetScopeEventCenter.shared.publish(NetScopeEvent(
                    kind: .reportReady, severity: .warning, title: "Courriel du rapport planifié en échec\u{00A0}: " + schedule.name,
                    detail: text + ".", link: .screen(Screen.rapports.rawValue), source: "rapport-courriel-" + schedule.id.uuidString))
            }
            show(text + ".", tone: failed ? .warning : .success)
        }
    }

    /// « Envoyer un essai… » (après confirmation) : produit le rapport maintenant et l'envoie aux
    /// destinataires de chaque site, même si l'envoi automatique n'est pas activé.
    func sendTest(_ id: UUID) {
        guard let schedule = book.schedules.first(where: { $0.id == id }) ?? (draft?.id == id ? draft : nil) else { return }
        let count = schedule.siteKeys.map { ReportMail.recipients(schedule, siteKey: $0).count }.reduce(0, +)
        if isDemo {
            show("Démonstration\u{00A0}: aucun courriel n’est envoyé (l’essai irait à \(count) destinataire\(count > 1 ? "s" : "")).", tone: .neutral)
            return
        }
        guard producing == nil, sending == nil else { return }
        if ScanController.shared.isRunning {
            show("Un scan est en cours\u{00A0}: l’essai sera possible à la fin du scan.", tone: .warning)
            return
        }
        guard book.schedules.contains(where: { $0.id == id }) else {
            show("Enregistrez d’abord le rapport planifié, puis envoyez l’essai depuis la liste.", tone: .warning)
            return
        }
        produce(id, slot: nil, now: Date(), testMail: true)
    }

    /// Destinataires de l'essai (confirmation).
    func testRecipients(_ schedule: ReportSchedule) -> String {
        let list = schedule.siteKeys.flatMap { ReportMail.recipients(schedule, siteKey: $0) }
        return list.isEmpty ? "aucun destinataire" : list.joined(separator: ", ")
    }

    /// « Produire maintenant » : hors échéance, sans toucher au calendrier du rapport planifié.
    func produceNow(_ id: UUID) {
        if isDemo {
            show("Démonstration\u{00A0}: aucun rapport n’est produit.", tone: .neutral)
            return
        }
        guard producing == nil else { return }
        if ScanController.shared.isRunning {
            show("Un scan est en cours\u{00A0}: le rapport sera possible à la fin du scan.", tone: .warning)
            return
        }
        produce(id, slot: nil, now: Date())
    }

    // MARK: Modification

    func newDraft() {
        let key = SiteModel.shared.activeKey
        let template = RapportModel.shared.config
        var config = ReportConfig(template: .audit, sections: [.resume, .suivi, .problemes], client: template.client,
                                  technician: template.technician, format: .pdf)
        config.maskMAC = template.maskMAC
        editedFrom = nil
        draft = ReportSchedule(name: "Suivi hebdomadaire — " + SiteModel.shared.name(forKey: key), siteKeys: [key],
                               cadence: .weekly, weekday: 2, hour: 7, minute: 0, config: config, activeSince: now)
    }

    func edit(_ id: UUID) {
        draft = book.schedules.first { $0.id == id }
        editedFrom = draft
    }

    /// Version de l'entrée au moment où l'éditeur s'est ouvert (pour savoir ce que l'éditeur a changé).
    private var editedFrom: ReportSchedule?

    var isNewDraft: Bool { draft.map { d in !book.schedules.contains { $0.id == d.id } } ?? false }

    /// Enregistre l'éditeur. Un changement de rythme ou d'heure ne rattrape rien du passé.
    func saveDraft() {
        guard var draft else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if draft.name.isEmpty { draft.name = "Rapport planifié" }
        if let index = book.schedules.firstIndex(where: { $0.id == draft.id }) {
            let old = book.schedules[index]
            // L'éditeur ne touche qu'à la configuration : l'état d'exécution (échéance produite
            // pendant que l'éditeur était ouvert, interrupteur de la liste) reste celui d'aujourd'hui.
            draft.lastSlot = old.lastSlot
            draft.lastProduced = old.lastProduced
            draft.lastStatus = old.lastStatus
            draft.lastMessage = old.lastMessage
            draft.lastFiles = old.lastFiles
            if let opened = editedFrom, opened.id == draft.id, opened.isEnabled == draft.isEnabled {
                draft.isEnabled = old.isEnabled
            }
            if old.cadence != draft.cadence || old.weekday != draft.weekday || old.monthDay != draft.monthDay
                || old.hour != draft.hour || old.minute != draft.minute || (!old.isEnabled && draft.isEnabled) {
                draft.activeSince = now
            }
            book.schedules[index] = draft
        } else {
            draft.activeSince = now
            book.schedules.append(draft)
        }
        self.draft = nil
        editedFrom = nil
        save()
        show("«\u{00A0}\(draft.name)\u{00A0}» enregistré. Prochain\u{00A0}: " + nextLabel(draft) + ".", tone: .success)
    }

    func setEnabled(_ enabled: Bool, _ id: UUID) {
        guard let index = book.schedules.firstIndex(where: { $0.id == id }) else { return }
        if enabled && !book.schedules[index].isEnabled { book.schedules[index].activeSince = now }
        book.schedules[index].isEnabled = enabled
        save()
    }

    func delete(_ id: UUID) {
        guard let index = book.schedules.firstIndex(where: { $0.id == id }) else { return }
        let name = book.schedules[index].name
        book.schedules.remove(at: index)
        if draft?.id == id { draft = nil }
        save()
        show("«\u{00A0}\(name)\u{00A0}» supprimé (les rapports déjà produits restent).", tone: .neutral)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Dossier des rapports planifiés"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft?.folder = url.path
    }

    func revealFolder(_ schedule: ReportSchedule) {
        if isDemo {
            show("Démonstration\u{00A0}: aucun dossier sur le disque.", tone: .neutral)
            return
        }
        let folder = schedule.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory
        // Nom relu du disque : on n'en garde que le dernier composant (jamais « .. » ni un chemin).
        let file = schedule.lastFiles.first.flatMap { RapportHistoryStore.safeFileName($0) }.map { folder.appendingPathComponent($0) }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.open(folder)
        } else {
            show("Dossier introuvable\u{00A0}: \(folder.path)", tone: .warning)
        }
    }

    // MARK: Libellés

    func nextLabel(_ schedule: ReportSchedule) -> String {
        guard schedule.isEnabled else { return "en pause" }
        guard !schedule.siteKeys.isEmpty else { return "aucun site choisi" }
        guard let next = ReportScheduler.nextSlot(after: now, schedule, calendar: calendar) else { return "—" }
        return ReportScheduler.dateLabel(next, now: now, calendar: calendar)
    }

    func sitesLabel(_ schedule: ReportSchedule) -> String {
        let names = schedule.siteKeys.map { SiteModel.shared.name(forKey: $0) }
        if names.isEmpty { return "Aucun site" }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) sites"
    }

    func folderLabel(_ schedule: ReportSchedule) -> String {
        schedule.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Dossier des rapports de NetScope"
    }

    private func save() {
        guard !isDemo else { return }
        do {
            try book.save(to: directory)
        } catch {
            show("Rapports planifiés non enregistrés\u{00A0}: \(error.localizedDescription)", tone: .critical)
        }
    }

    func show(_ text: String, tone: Tone) {
        message = (text, tone)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
