import AppKit
import NetScopeCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// État de l'écran Rapports : réglages du rapport, logo, rapports récents et modèles enregistrés.
/// Les fichiers vont dans ~/Library/Application Support/NetScope/rapports/ (index.json, logo,
/// rapports produits). En démonstration, rien n'est lu ni écrit là : les rapports produits vont
/// dans un dossier temporaire.
@MainActor
final class RapportModel: ObservableObject {
    static let shared = RapportModel()

    @Published var config: ReportConfig
    /// Page affichée dans l'aperçu (1…).
    @Published var page = 1
    @Published private(set) var library: ReportLibrary
    @Published private(set) var logo: NSImage?
    @Published var emailOpen = false
    @Published var emailTo = ""
    @Published var toast: String?
    /// Dernier fichier produit (bouton « Afficher dans le Finder » du message).
    @Published private(set) var lastFile: URL?

    let isDemo: Bool
    let directory: URL
    private var toastTask: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
        if demo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-rapports-demo", isDirectory: true)
            // Captures de développement : NETSCOPE_RAPPORT_COURRIEL=1 coche la section « Santé courriel ».
            var demo = RapportDemo.config
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_COURRIEL"] == "1" { demo.sections.insert(.courriel) }
            // NETSCOPE_RAPPORT_DISQUES=1 coche la section « Vitesse des disques ».
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_DISQUES"] == "1" { demo.sections.insert(.disques) }
            // NETSCOPE_RAPPORT_FORTIAP=1 coche la section « Wi-Fi FortiAP ».
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_FORTIAP"] == "1" { demo.sections.insert(.fortiap) }
            // NETSCOPE_RAPPORT_DHCP=1 coche la section « Étendues DHCP ».
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_DHCP"] == "1" { demo.sections.insert(.dhcp) }
            // NETSCOPE_RAPPORT_WIFIDIAG=1 coche la section « Diagnostic Wi-Fi ».
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_WIFIDIAG"] == "1" { demo.sections.insert(.wifiDiag) }
            // NETSCOPE_RAPPORT_RACCORDEMENT=1 coche la section « Bilan de raccordement » (note 58).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_RACCORDEMENT"] == "1" { demo.sections.insert(.raccordement) }
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_WAN"] == "1" { demo.sections.insert(.wan) }
            // NETSCOPE_RAPPORT_TRAFIC=1 coche la section « Trafic et analyse » (note 54).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_TRAFIC"] == "1" { demo.sections.insert(.trafic) }
            // NETSCOPE_RAPPORT_FIRMWARE=1 coche la section « Firmware et licences » (note 41).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_FIRMWARE"] == "1" { demo.sections.insert(.firmware) }
            // NETSCOPE_RAPPORT_SUIVI=1 coche la section « Depuis le dernier rapport » (note 42).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_SUIVI"] == "1" { demo.sections.insert(.suivi) }
            // NETSCOPE_RAPPORT_DISPO=1 coche la section « Disponibilité (Surveillance) » (note 78).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_DISPO"] == "1" { demo.sections.insert(.disponibilite) }
            // NETSCOPE_RAPPORT_CARTE=1 coche la section « Carte du réseau » (note 61).
            if ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_CARTE"] == "1" { demo.sections.insert(.carte) }
            // NETSCOPE_RAPPORT_PAGE=2 : page montrée dans l'aperçu (captures).
            if let wanted = ProcessInfo.processInfo.environment["NETSCOPE_RAPPORT_PAGE"].flatMap(Int.init), wanted > 1 { page = wanted }
            config = demo
            library = ReportLibrary(recents: RapportDemo.recents)
        } else {
            directory = ReportLibrary.defaultDirectory
            library = ReportLibrary.load(from: directory)
            config = ReportConfig(technician: NSFullUserName(), date: ReportText.isoDay(Date()))
            logo = Self.logoURL(in: directory).flatMap(NSImage.init(contentsOf:))
        }
    }

    // MARK: Document

    /// Rapport du site actif ; plusieurs sites choisis (menu « Site ▾ ») : rapport multisite, une
    /// section par site.
    func document(state: AppState) -> ReportDocument {
        document(for: siteInputs(state: state))
    }

    /// Données de chaque site du rapport (clé du site et entrée), dans l'ordre du menu « Site ▾ ».
    func siteInputs(state: AppState) -> [(key: String, site: ReportSiteInput)] {
        let keys = SiteScopeStore.shared.keys(for: .rapports)
        let floors = config.includes(.releveWifi)
        if keys == [SiteModel.shared.activeKey] {
            var input = RapportData.input(state: state, demo: isDemo, map: config.includes(.carte))
            // Note 94 : relevé Wi-Fi sur plan (images dessinées seulement si la section est cochée).
            if floors { input.floorSurvey = WifiFloorStore.shared.reportFloors(siteKey: keys[0]) }
            Self.addPrintersAndVoIP(&input, siteKey: keys[0], config: config, active: true)
            return [(keys[0], ReportSiteInput(name: SiteModel.shared.activeName, input: input))]
        }
        return zip(keys, RapportData.inputs(state: state, demo: isDemo, keys: keys, map: config.includes(.carte)))
            .map { pair in
                var site = pair.1
                if floors { site.input.floorSurvey = WifiFloorStore.shared.reportFloors(siteKey: pair.0) }
                Self.addPrintersAndVoIP(&site.input, siteKey: pair.0, config: config, active: pair.0 == SiteModel.shared.activeKey)
                return (key: pair.0, site: site)
            }
    }

    /// Notes 91 et 92 : imprimantes relevées du site ; mesures VoIP (appels de la dernière capture,
    /// test simulé) seulement pour le site actif, où elles ont été faites.
    static func addPrintersAndVoIP(_ input: inout ReportInput, siteKey: String, config: ReportConfig, active: Bool) {
        if config.includes(.imprimantes) {
            input.printers = PrinterStore.shared.reportPrinters(devices: input.devices, siteKey: siteKey)
        }
        // Note 98 : onduleurs relevés du site (fiche ou sonde), comme les imprimantes.
        if config.includes(.onduleurs) {
            input.upsUnits = UPSStore.shared.reportUnits(devices: input.devices, siteKey: siteKey)
        }
        if config.includes(.voip), active {
            input.voipCalls = VoIPReportSource.calls()
            input.voipTests = VoIPReportSource.tests()
        }
        // Notes 96 et 97 : relevés du site actif seulement (Test DHCP, ARP de ce Mac, balayage).
        if config.includes(.pirates), active {
            let pirates = PirateStore.shared
            input.rogueDHCP = pirates.dhcpFindings
            input.ipConflicts = pirates.ipConflicts(devices: input.devices)
            input.rogueAPs = pirates.rogueAPs(devices: input.devices)
        }
    }

    func document(for inputs: [(key: String, site: ReportSiteInput)]) -> ReportDocument {
        let generator = "NetScope \(AppInfo.version)"
        if inputs.count == 1, inputs[0].key == SiteModel.shared.activeKey, menuSiteNames == nil {
            return ReportBuilder.build(config: config, input: inputs[0].site.input, generator: generator)
        }
        var chosen = config
        // Un seul autre site : son nom dans l'en-tête (pas celui du site actif).
        if inputs.count == 1, let only = inputs.first { chosen.site = only.site.name }
        return ReportBuilder.buildMultisite(config: chosen, sites: inputs.map(\.site), generator: generator)
    }

    /// Sites du rapport quand ce n'est pas le site actif seul (menu « Site ▾ ») : ils remplacent le
    /// champ « Site » dans l'en-tête et le nom du fichier.
    var menuSiteNames: String? {
        let keys = SiteScopeStore.shared.keys(for: .rapports)
        guard keys != [SiteModel.shared.activeKey] else { return nil }
        return keys.map { SiteModel.shared.name(forKey: $0) }.joined(separator: ", ")
    }

    /// Nom du fichier produit : celui des sites du rapport.
    func fileName(for format: ReportFormat) -> String {
        var named = config
        if let names = menuSiteNames { named.site = names }
        return named.fileName(for: format)
    }

    func pages(for document: ReportDocument) -> [ReportPage] {
        ReportPaginator.paginate(document)
    }

    // MARK: Réglages

    func pick(_ template: ReportTemplate) {
        config.apply(template)
        page = 1
    }

    func toggle(_ section: ReportSectionKind) {
        if config.sections.contains(section) { config.sections.remove(section) } else { config.sections.insert(section) }
    }

    func newReport() {
        let technician = config.technician
        config = ReportConfig(technician: technician, date: ReportText.isoDay(Date()))
        if isDemo { config.site = RapportDemo.config.site; config.date = RapportDemo.config.date }
        page = 1
        emailOpen = false
        show("Nouveau rapport à partir du modèle Audit réseau complet.")
    }

    /// Note 28 : le site actif dans l'en-tête du rapport (le rapport ne décrit que ce site).
    private var siteFromModel: String?

    func siteChanged(_ site: Site?) {
        let name = site?.displayName ?? ""
        let current = config.site.trimmingCharacters(in: .whitespaces)
        // Un site saisi à la main reste, sauf s'il venait du site précédent.
        guard current.isEmpty || current == siteFromModel || (isDemo && current == RapportDemo.config.site) else { return }
        config.site = name
        siteFromModel = name
    }

    func saveTemplate() {
        let site = config.site.trimmingCharacters(in: .whitespaces)
        let name = config.template.label + (site.isEmpty ? "" : " — \(site)")
        library.save(ReportSavedTemplate(name: name, config: config))
        persist()
        show("Modèle enregistré\u{00A0}: «\u{00A0}\(name)\u{00A0}» avec \(config.sections.count) sections, format \(config.format.label).")
    }

    func apply(_ saved: ReportSavedTemplate) {
        var next = saved.config
        next.date = config.date
        config = next
        page = 1
        show("Modèle «\u{00A0}\(saved.name)\u{00A0}» appliqué.")
    }

    var dateValue: Date {
        get {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: config.date) ?? Date()
        }
        set { config.date = ReportText.isoDay(newValue) }
    }

    // MARK: Logo

    static func logoURL(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasPrefix("logo.") }.map { directory.appendingPathComponent($0) }
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.title = "Choisir le logo de l’entreprise"
        panel.prompt = "Choisir"
        panel.allowedContentTypes = [.png, .jpeg, .svg, .pdf, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), image.isValid else {
            show("Image illisible\u{00A0}: choisissez un fichier PNG, JPEG, SVG ou PDF.")
            return
        }
        logo = image
        guard !isDemo else { return }
        let fm = FileManager.default
        let old = Self.logoURL(in: directory)
        // Le logo déjà enregistré choisi de nouveau : rien à copier.
        if let old, old.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            show("Ce logo est déjà enregistré.")
            return
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            // Copie d'abord sous un nom temporaire : l'ancien logo n'est retiré qu'une fois la copie réussie.
            let temporary = directory.appendingPathComponent(".logo-\(UUID().uuidString).\(ext)")
            try fm.copyItem(at: url, to: temporary)
            let target = directory.appendingPathComponent("logo.\(ext)")
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: target)
            }
            if let old, old.lastPathComponent != target.lastPathComponent { try? fm.removeItem(at: old) }
            show("Logo enregistré\u{00A0}: il remplace [VOTRE LOGO] sur toutes les pages.")
        } catch {
            show("Logo affiché, mais pas enregistré\u{00A0}: \(error.localizedDescription)")
        }
    }

    func removeLogo() {
        logo = nil
        if !isDemo, let old = Self.logoURL(in: directory) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Production des fichiers

    /// Écrit le rapport dans le dossier des rapports, au format choisi ; nil en cas d'échec.
    @discardableResult
    func generate(state: AppState, format: ReportFormat? = nil, quiet: Bool = false) -> URL? {
        let format = format ?? config.format
        guard config.isDateValid else {
            show("Date invalide\u{00A0}: indiquez une date au format AAAA-MM-JJ avant de générer le rapport.")
            return nil
        }
        let inputs = siteInputs(state: state)
        let document = document(for: inputs)
        let pages = pages(for: document)
        guard let data = render(document, pages: pages, format: format) else {
            show("Le rapport n’a pas pu être produit.")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = ReportLibrary.availableName(fileName(for: format), in: directory)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            let site = document.site.trimmingCharacters(in: .whitespaces)
            library.add(ReportRecent(title: config.template.shortTitle + " — " + (site.isEmpty ? "Site" : site), fileName: name,
                                     format: format, date: config.date,
                                     pages: format == .pdf ? pages.count : nil,
                                     rows: format == .csv ? ReportExport.csvRowCount(document) : nil,
                                     technician: config.technician))
            persist()
            lastFile = url
            // Note 42 : instantané de chaque site du rapport, base du prochain rapport de suivi.
            for entry in inputs {
                RapportHistoryStore.shared.record(ReportSnapshot.make(
                    input: entry.site.input, siteKey: entry.key, siteName: entry.site.name, created: Date(), reportDate: config.date,
                    title: config.template.shortTitle + " — " + entry.site.name, fileName: name, format: format))
            }
            if !quiet { show("Rapport généré\u{00A0}: \(name) (enregistré dans Application Support/NetScope/rapports)") }
            return url
        } catch {
            show("Enregistrement impossible\u{00A0}: \(error.localizedDescription)")
            return nil
        }
    }

    func printReport(state: AppState) {
        let document = document(state: state)
        let pages = pages(for: document)
        guard let data = RapportPDF.render(document, pages: pages, logo: logo), let pdf = PDFDocument(data: data) else {
            show("Impression impossible\u{00A0}: le PDF n’a pas pu être produit.")
            return
        }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false) else { return }
        operation.jobTitle = document.title
        operation.run()
    }

    /// Prépare un brouillon dans Mail avec le PDF joint ; rien n'est envoyé : l'utilisateur relit et envoie.
    func emailDraft(state: AppState) {
        let recipient = emailTo.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty else {
            show("Indiquez un destinataire avant de préparer le brouillon.")
            return
        }
        guard let url = generate(state: state, format: .pdf, quiet: true) else { return }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [url]) else {
            show("Aucune app de courriel configurée\u{00A0}: le PDF est dans le dossier des rapports.")
            return
        }
        service.recipients = [recipient]
        service.subject = emailSubject
        let body = "Bonjour,\n\nVous trouverez ci-joint le document «\u{00A0}\(config.documentTitle)\u{00A0}» du \(config.dateLabel).\n\n"
        service.perform(withItems: [body, url])
        emailOpen = false
        show("Brouillon prêt dans Mail pour \(recipient) (rien n’est envoyé).")
    }

    var emailSubject: String { config.documentTitle + " — " + config.dateLabel }

    /// Contenu du fichier au format choisi (le PDF est dessiné page par page ; le DOCX est écrit à la main).
    func render(_ document: ReportDocument, pages: [ReportPage], format: ReportFormat) -> Data? {
        switch format {
        case .pdf: return RapportPDF.render(document, pages: pages, logo: logo)
        case .csv: return ReportExport.csvData(document)
        case .json: return try? ReportExport.json(document)
        case .html: return Data(ReportExport.html(document, logoDataURL: RapportPDF.dataURL(logo)).utf8)
        case .docx: return ReportDocx.make(document, logoPNG: RapportPDF.pngData(logo))
        }
    }

    // MARK: Rapports planifiés (note 42)

    /// Produit le rapport planifié d'un site, sans jamais lancer de scan : le site actif d'après le
    /// dernier scan de la session, les autres d'après leur dernier scan enregistré. La première
    /// section dit l'âge du scan repris. Renvoie le fichier écrit, ou le message d'échec.
    func produceScheduled(_ schedule: ReportSchedule, siteKey: String, slot: Date, state: AppState,
                          now: Date = Date()) -> Result<URL, ScheduledReportError> {
        let sites = SiteModel.shared
        guard siteKey == sites.activeKey || sites.site(forKey: siteKey) != nil else {
            return .failure(ScheduledReportError("site introuvable (supprimé\u{00A0}?)"))
        }
        let name = sites.name(forKey: siteKey)
        var input = siteKey == sites.activeKey
            ? RapportData.input(state: state, demo: isDemo, now: now, followUpBase: .last, map: schedule.config.includes(.carte))
            : RapportData.input(forSite: siteKey, now: now, followUpBase: .last, map: schedule.config.includes(.carte), state: state)
        input.now = now
        if schedule.config.includes(.releveWifi) { input.floorSurvey = WifiFloorStore.shared.reportFloors(siteKey: siteKey) }
        Self.addPrintersAndVoIP(&input, siteKey: siteKey, config: schedule.config, active: siteKey == sites.activeKey)
        var config = schedule.config
        config.site = name
        config.date = ReportText.isoDay(now)
        if config.technician.trimmingCharacters(in: .whitespaces).isEmpty { config.technician = self.config.technician }
        var document = ReportBuilder.build(config: config, input: input, generator: "NetScope \(AppInfo.version)")
        let calendar = ReportScheduler.calendar()
        ReportScheduler.annotate(&document, note: ReportScheduler.scanNote(scanDate: input.scanDate, now: now, calendar: calendar))
        let pages = pages(for: document)
        guard let data = render(document, pages: pages, format: config.format) else {
            return .failure(ScheduledReportError("le document n’a pas pu être produit"))
        }
        let folder = schedule.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let wanted = ReportScheduler.fileName(pattern: schedule.fileNamePattern, siteName: name, config: config, slot: slot,
                                                  format: config.format, calendar: calendar)
            let fileName = ReportLibrary.availableName(wanted, in: folder)
            let url = folder.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            let title = config.template.shortTitle + " — " + name
            if schedule.folder == nil {
                library.add(ReportRecent(title: title, fileName: fileName, format: config.format, date: config.date,
                                         pages: config.format == .pdf ? pages.count : nil,
                                         rows: config.format == .csv ? ReportExport.csvRowCount(document) : nil,
                                         technician: config.technician))
                persist()
            }
            RapportHistoryStore.shared.record(ReportSnapshot.make(
                input: input, siteKey: siteKey, siteName: name, created: now, reportDate: config.date, title: title, fileName: fileName,
                folder: schedule.folder, format: config.format, scheduleName: schedule.name))
            return .success(url)
        } catch {
            return .failure(ScheduledReportError(error.localizedDescription))
        }
    }

    /// Ouvre un brouillon dans Mail avec les fichiers joints ; rien n'est envoyé. Faux si aucune app de courriel.
    @discardableResult
    func openDraft(to recipient: String, subject: String, body: String, files: [URL]) -> Bool {
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else { return false }
        let to = recipient.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty { service.recipients = [to] }
        service.subject = subject
        service.perform(withItems: [body] + files)
        return true
    }

    // MARK: Rapports récents

    var recents: [ReportRecent] {
        isDemo ? library.recents : library.existingRecents(in: directory)
    }

    func open(_ recent: ReportRecent) {
        let url = directory.appendingPathComponent(recent.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            show("Fichier introuvable\u{00A0}: \(recent.fileName)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Note 42 : un rapport passé supprimé quitte aussi la liste des rapports récents.
    func forgetRecent(fileName: String) {
        library.remove(fileName: fileName)
        persist()
    }

    func revealLastFile() {
        guard let lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    // MARK: Divers

    private func persist() {
        guard !isDemo else { return }
        do {
            try library.save(to: directory)
        } catch {
            AppLog.shared.error("Rapports", "Index des rapports non enregistré\u{00A0}:\u{00A0}\(error.localizedDescription)")
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

/// Échec d'un rapport planifié (message en clair).
struct ScheduledReportError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
