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

    func document(state: AppState) -> ReportDocument {
        ReportBuilder.build(config: config, input: RapportData.input(state: state, demo: isDemo),
                            generator: "NetScope \(AppInfo.version)")
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
        let document = document(state: state)
        let pages = pages(for: document)
        let data: Data?
        switch format {
        case .pdf: data = RapportPDF.render(document, pages: pages, logo: logo)
        case .csv: data = ReportExport.csvData(document)
        case .json: data = try? ReportExport.json(document)
        case .html: data = Data(ReportExport.html(document, logoDataURL: RapportPDF.dataURL(logo)).utf8)
        }
        guard let data else {
            show("Le rapport n’a pas pu être produit.")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = ReportLibrary.availableName(config.fileName(for: format), in: directory)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            let site = config.site.trimmingCharacters(in: .whitespaces)
            library.add(ReportRecent(title: config.template.shortTitle + " — " + (site.isEmpty ? "Site" : site), fileName: name,
                                     format: format, date: config.date,
                                     pages: format == .pdf ? pages.count : nil,
                                     rows: format == .csv ? ReportExport.csvRowCount(document) : nil,
                                     technician: config.technician))
            persist()
            lastFile = url
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
            NSLog("NetScope\u{00A0}: index des rapports non enregistré\u{00A0}:\u{00A0}%@", error.localizedDescription)
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
