import AppKit
import NetScopeCore
import SwiftUI

/// Outil « TFTP » (note 51) : serveur TFTP temporaire sur le Mac et client TFTP.
///
/// Le serveur n'est jamais lancé tout seul : bouton Démarrer, arrêt d'un bouton ou automatique
/// après un délai sans transfert. Réglages (non secrets) dans UserDefaults « tftp.* » ; journal des
/// transferts, par site, dans ~/Library/Application Support/NetScope/tftp.json. En démonstration
/// et pendant les captures, rien n'est lu ni écrit, et rien ne part sur le réseau (TFTPDemo).
@MainActor
final class TFTPModel: ObservableObject {
    static let shared = TFTPModel()

    enum Mode: String, CaseIterable, Identifiable {
        case serveur, client
        var id: String { rawValue }
        var label: String { self == .serveur ? "Serveur sur ce Mac" : "Client" }
    }

    /// Délais d'arrêt automatique proposés (minutes ; 0 : jamais).
    static let autoStopChoices = [5, 15, 30, 60, 0]
    static let blockSizeChoices = [512, 1_024, TFTPLimits.ethernetBlockSize, 8_192, TFTPLimits.maxBlockSize]
    static let windowChoices = [1, 2, 4, 8, 16, 32]
    static let timeoutChoices = [1, 2, 3, 5, 10]
    static let retryChoices = [3, 5, 8, 12]
    /// Port proposé quand 69 est pris (tftpd de macOS) : au-dessus de 1024, jamais réservé.
    static let alternatePort: UInt16 = 6969

    @Published var mode: Mode = .serveur

    // MARK: Serveur — réglages

    @Published var rootPath: String { didSet { save("tftp.dossier", rootPath); refreshFiles() } }
    /// Interface d'écoute (nom BSD) ; nil : toutes.
    @Published var interfaceName: String? { didSet { save("tftp.interface", interfaceName ?? "") } }
    @Published var portText: String { didSet { save("tftp.port", portText) } }
    @Published var allowWrite: Bool { didSet { save("tftp.ecriture", allowWrite) } }
    @Published var allowOverwrite: Bool { didSet { save("tftp.ecraser", allowOverwrite) } }
    @Published var autoStopMinutes: Int { didSet { save("tftp.arret", autoStopMinutes) } }
    @Published var maxBlockSize: Int { didSet { save("tftp.blksize", maxBlockSize) } }
    @Published var maxWindowSize: Int { didSet { save("tftp.fenetre", maxWindowSize) } }
    @Published var timeout: Int { didSet { save("tftp.delai", timeout) } }
    @Published var retries: Int { didSet { save("tftp.essais", retries) } }
    /// Demande de confirmation avant d'autoriser l'écrasement.
    @Published var confirmingOverwrite = false

    // MARK: Serveur — état

    @Published private(set) var isRunning = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var startedAt: Date?
    @Published private(set) var startError: String?
    /// Le port demandé est occupé : proposer le port de rechange.
    @Published private(set) var portBusy = false
    @Published private(set) var stopMessage: String?
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var interfaces: [LocalInterface] = []
    @Published private(set) var files: [TFTPSharedFile] = []
    @Published private(set) var firewall: TFTPFirewallStatus?
    /// Requêtes ignorées (autre interface, paquet illisible) depuis le démarrage.
    @Published private(set) var ignored: [String] = []
    @Published private(set) var activeTransfers = 0

    // MARK: Client

    @Published var clientHost = ""
    @Published var clientPortText = "69"
    @Published var clientDirection: TFTPClient.Direction = .get
    @Published var remoteName = ""
    /// Fichier à envoyer (put) ou fichier où enregistrer (get).
    @Published var localPath = ""
    @Published var clientBlockSize = TFTPLimits.ethernetBlockSize
    @Published var clientWindow = 1
    @Published var clientTimeout = 3
    @Published var clientRetries = TFTPLimits.defaultRetries
    @Published var clientMode: TFTPMode = .octet
    @Published var clientUseOptions = true
    @Published private(set) var clientRunning = false
    @Published private(set) var clientBytes: Int64 = 0
    @Published private(set) var clientTotal: Int64?
    @Published private(set) var clientResult: (tone: Tone, title: String, message: String)?

    // MARK: Journal

    @Published private(set) var records: [TFTPTransferRecord] = []

    let isDemo: Bool
    let isEphemeral: Bool
    private let defaults: UserDefaults?
    private let url: URL
    private var server: TFTPServer?
    private var lastActivity = Date()
    private var timer: Timer?
    private var deviceNames: [String: String] = [:]
    private var clientCancel = TFTPCancelFlag()

    private init() {
        let arguments = CommandLine.arguments
        isDemo = arguments.contains("--demo")
        isEphemeral = isDemo || arguments.contains("--snapshot")
        defaults = isEphemeral ? nil : UserDefaults.standard
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("tftp.json")
        let stored = defaults
        rootPath = stored?.string(forKey: "tftp.dossier") ?? Self.defaultRoot.path
        let savedInterface = stored?.string(forKey: "tftp.interface") ?? ""
        interfaceName = savedInterface.isEmpty ? nil : savedInterface
        portText = stored?.string(forKey: "tftp.port") ?? "69"
        allowWrite = stored?.bool(forKey: "tftp.ecriture") ?? false
        allowOverwrite = stored?.bool(forKey: "tftp.ecraser") ?? false
        autoStopMinutes = (stored?.object(forKey: "tftp.arret") as? Int) ?? 15
        maxBlockSize = (stored?.object(forKey: "tftp.blksize") as? Int) ?? TFTPLimits.maxBlockSize
        maxWindowSize = (stored?.object(forKey: "tftp.fenetre") as? Int) ?? 16
        timeout = (stored?.object(forKey: "tftp.delai") as? Int) ?? 3
        retries = (stored?.object(forKey: "tftp.essais") as? Int) ?? TFTPLimits.defaultRetries
        if isDemo {
            TFTPDemo.apply(to: self)
        } else if !isEphemeral, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let saved = try? decoder.decode([TFTPTransferRecord].self, from: data) {
                records = TFTPHistory.closingInterrupted(saved)
            }
        }
    }

    /// Dossier partagé par défaut : ~/Documents/NetScope TFTP (créé au premier démarrage).
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("NetScope TFTP", isDirectory: true)
    }

    var rootURL: URL { URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true) }

    /// « NetScope TFTP » : nom court du dossier.
    var rootName: String { rootURL.lastPathComponent }

    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    var selectedInterface: LocalInterface? {
        interfaceName.flatMap { name in interfaces.first { $0.name == name } }
    }

    /// Adresse du Mac à donner à l'appareil : celle de l'interface choisie, sinon de l'interface active.
    func macAddress(state: AppState) -> IPv4Address? {
        selectedInterface?.address ?? state.activeInterface?.address ?? interfaces.first?.address
    }

    /// Adresses où le serveur répond (toutes les interfaces, ou celle choisie).
    var listeningAddresses: [LocalInterface] {
        if let selectedInterface { return [selectedInterface] }
        return interfaces
    }

    /// Transferts du site actif, le plus récent d'abord.
    var siteRecords: [TFTPTransferRecord] {
        TFTPHistory.forSite(siteKey, in: records)
    }

    var siteKey: String? { SiteModel.shared.activeID == nil ? nil : SiteModel.shared.activeKey }

    // MARK: Commande équivalente

    var command: String {
        switch mode {
        case .serveur:
            let address = selectedInterface?.address.description ?? "0.0.0.0"
            let home = NSHomeDirectory()
            let folder = rootPath.hasPrefix(home + "/") ? "~" + rootPath.dropFirst(home.count) : rootPath
            return "in.tftpd -L\(allowWrite ? " -c" : "") -a \(address):\(portText) -s \"\(folder)\""
        case .client:
            let host = clientHost.trimmingCharacters(in: .whitespaces).isEmpty ? "<appareil>" : clientHost.trimmingCharacters(in: .whitespaces)
            let portPart = clientPortText == "69" ? "" : ":\(clientPortText)"
            let name = remoteName.isEmpty ? "<fichier>" : remoteName
            let local = localPath.isEmpty ? (clientDirection == .get ? name : "<fichier>") : (localPath as NSString).lastPathComponent
            let block = clientUseOptions && clientBlockSize != 512 ? " --tftp-blksize \(clientBlockSize)" : ""
            switch clientDirection {
            case .get: return "curl\(block) -o \"\(local)\" tftp://\(host)\(portPart)/\(name)"
            case .put: return "curl\(block) -T \"\(local)\" tftp://\(host)\(portPart)/\(name)"
            }
        }
    }

    // MARK: Interfaces, fichiers, coupe-feu

    /// Relit les interfaces, les fichiers du partage et le coupe-feu (lectures locales seulement).
    func refresh() {
        guard !isDemo else { return }
        Task {
            let list = await LocalInterfaces.listWithKinds()
            interfaces = list
            if let name = interfaceName, !list.contains(where: { $0.name == name }), !isRunning { interfaceName = nil }
        }
        refreshFiles()
        Task { firewall = await TFTPFirewallStatus.read(appPath: Bundle.main.bundlePath) }
    }

    func refreshFiles() {
        guard !isDemo else { return }
        let access = TFTPFileAccess(root: rootURL)
        Task.detached(priority: .utility) {
            let list = access.listing()
            await MainActor.run { TFTPModel.shared.files = list }
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Partager ce dossier"
        panel.message = "Dossier servi par le serveur TFTP\u{00A0}: les appareils n’auront accès qu’à ce dossier."
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        rootPath = chosen.path
    }

    func revealRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }

    // MARK: Démarrer et arrêter

    func start(state: AppState) {
        guard !isRunning else { return }
        startError = nil
        portBusy = false
        stopMessage = nil
        guard let port else {
            startError = "Port invalide\u{00A0}: un nombre de 1 à 65\u{00A0}535."
            return
        }
        if isDemo {
            isRunning = true
            startedAt = Date()
            listeningPort = port
            return
        }
        // Le dossier par défaut est créé au besoin ; un dossier choisi doit exister.
        if rootURL == Self.defaultRoot, !FileManager.default.fileExists(atPath: rootURL.path) {
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        deviceNames = Dictionary(state.devices.map { ($0.ip.description, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let configuration = TFTPServer.Configuration(
            root: rootURL, port: port, listenAddress: selectedInterface?.address, allowWrite: allowWrite,
            allowOverwrite: allowWrite && allowOverwrite,
            policy: TFTPServerPolicy(maxBlockSize: maxBlockSize, maxWindowSize: maxWindowSize, timeout: TimeInterval(timeout),
                                     retries: retries, maxWriteSize: 8 << 30))
        let server = TFTPServer(configuration: configuration) { event in
            DispatchQueue.main.async { TFTPModel.shared.apply(event) }
        }
        do {
            try server.start()
        } catch let error as TFTPBindError {
            startError = error.errorDescription
            portBusy = error.isInUse
            return
        } catch {
            startError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        self.server = server
        isRunning = true
        startedAt = Date()
        listeningPort = server.boundPort
        lastActivity = Date()
        ignored = []
        let address = macAddress(state: state)?.description ?? "0.0.0.0"
        ToolStore.shared.record(command: command)
        ToolStore.shared.record(ToolRecent(tool: .tftp, target: "\(address):\(server.boundPort)",
                                           summary: "Serveur démarré · dossier «\u{00A0}\(rootName)\u{00A0}» · " + (allowWrite ? "lecture et écriture" : "lecture seule"),
                                           status: .info, title: "Serveur TFTP"))
        startTimer()
        refresh()
    }

    /// Arrêt demandé (bouton) ou automatique.
    func stop(reason: String? = nil) {
        guard isRunning else { return }
        server?.stop()
        server = nil
        isRunning = false
        timer?.invalidate()
        timer = nil
        remaining = nil
        activeTransfers = 0
        stopMessage = reason
        if let startedAt {
            let session = records.filter { $0.role == .server && $0.date >= startedAt }
            let done = session.filter { $0.status == .done }.count
            let failed = session.filter { $0.status == .failed || $0.status == .refused }.count
            let summary = session.isEmpty ? "Aucun transfert" : "\(session.count) transfert\(session.count > 1 ? "s" : "") · \(done) réussi\(done > 1 ? "s" : "")"
                + (failed > 0 ? " · \(failed) en échec ou refusé\(failed > 1 ? "s" : "")" : "")
            ToolStore.shared.record(ToolRecent(tool: .tftp, target: "port \(listeningPort.map(String.init) ?? portText)",
                                               summary: "Serveur arrêté · " + summary, status: failed > 0 ? .warning : .ok,
                                               title: "Serveur TFTP"))
        }
        startedAt = nil
    }

    func useAlternatePort() {
        portText = String(Self.alternatePort)
        startError = nil
        portBusy = false
    }

    private func startTimer() {
        timer?.invalidate()
        updateRemaining()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in TFTPModel.shared.updateRemaining() }
        }
    }

    private func updateRemaining() {
        guard isRunning else { return }
        let delay = autoStopMinutes > 0 ? TimeInterval(autoStopMinutes * 60) : nil
        activeTransfers = server?.activeTransfers ?? 0
        if activeTransfers > 0 { lastActivity = Date() }
        remaining = TFTPAutoStop.remaining(lastActivity: lastActivity, delay: delay, activeTransfers: activeTransfers)
        if let remaining, remaining <= 0 {
            stop(reason: "Arrêté automatiquement après \(autoStopMinutes)\u{00A0}min sans transfert.")
        }
    }

    // MARK: Événements du serveur

    private func apply(_ event: TFTPServer.Event) {
        lastActivity = Date()
        switch event {
        case .listening:
            break
        case .started(let transfer):
            var record = TFTPTransferRecord(id: transfer.id, date: transfer.date, role: .server,
                                            flow: transfer.kind == .read ? .toDevice : .fromDevice,
                                            peer: transfer.peer.description, peerName: deviceNames[transfer.peer.description],
                                            filename: TFTPPath.display(transfer.filename), total: transfer.size, site: siteKey,
                                            blockSize: transfer.settings?.blockSize, windowSize: transfer.settings?.windowSize)
            record.detail = Self.optionsText(transfer.settings, mode: transfer.mode)
            upsert(record, persist: false)
        case .progress(let id, let bytes):
            guard var record = records.first(where: { $0.id == id }) else { return }
            record.bytes = bytes
            record.seconds = Date().timeIntervalSince(record.date)
            upsert(record, persist: false)
        case .finished(let id, let bytes, let seconds, let retransmissions):
            guard var record = records.first(where: { $0.id == id }) else { return }
            record.bytes = bytes
            record.seconds = seconds
            record.status = .done
            if retransmissions > 0 { record.detail += " · \(retransmissions) retransmission\(retransmissions > 1 ? "s" : "")" }
            upsert(record, persist: true)
            refreshFiles()
        case .failed(let id, let failure, let bytes, let seconds):
            guard var record = records.first(where: { $0.id == id }) else { return }
            record.bytes = bytes
            record.seconds = seconds
            record.status = failure == .cancelled ? .cancelled : .failed
            record.reason = failure.shortLabel
            record.detail = failure == .cancelled ? "Serveur arrêté pendant le transfert." : (failure.errorDescription ?? "Échec")
            upsert(record, persist: true)
        case .refused(let transfer, let failure):
            let record = TFTPTransferRecord(id: transfer.id, date: transfer.date, role: .server,
                                            flow: transfer.kind == .read ? .toDevice : .fromDevice,
                                            peer: transfer.peer.description, peerName: deviceNames[transfer.peer.description],
                                            filename: TFTPPath.display(transfer.filename), status: .refused,
                                            detail: failure.errorDescription ?? "Refusé", site: siteKey, reason: failure.shortLabel)
            upsert(record, persist: true)
        case .ignored(let peer, let reason):
            ignored.insert("\(ToolText.time(Date())) · \(peer) · \(reason)", at: 0)
            if ignored.count > 20 { ignored.removeLast(ignored.count - 20) }
        case .stopped(let message):
            if let message, isRunning {
                stop(reason: message)
            }
        }
        activeTransfers = server?.activeTransfers ?? 0
    }

    static func optionsText(_ settings: TFTPTransferSettings?, mode: TFTPMode) -> String {
        guard let settings else { return mode == .netascii ? "netascii" : "octet" }
        var parts = ["blksize \(settings.blockSize)"]
        if settings.windowSize > 1 { parts.append("fenêtre \(settings.windowSize)") }
        if let size = settings.transferSize { parts.append("tsize \(TFTPFormat.bytes(size))") }
        parts.append(mode == .netascii ? "netascii" : "octet")
        return parts.joined(separator: " · ")
    }

    // MARK: Client

    /// Prépare le client pour un appareil (Scanner, fiche Appareil) et ouvre l'outil.
    func prepareClient(for device: Device, state: AppState) {
        mode = .client
        clientHost = device.ip.description
        ToolStore.shared.open(.tftp, in: state)
    }

    func chooseLocalFile() {
        switch clientDirection {
        case .put:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Envoyer ce fichier"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            localPath = chosen.path
            if remoteName.isEmpty { remoteName = chosen.lastPathComponent }
        case .get:
            let panel = NSSavePanel()
            panel.prompt = "Enregistrer"
            panel.nameFieldStringValue = remoteName.isEmpty ? "fichier-tftp" : (remoteName as NSString).lastPathComponent
            panel.canCreateDirectories = true
            // NSSavePanel demande confirmation avant d'écraser un fichier existant.
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            localPath = chosen.path
        }
    }

    var clientValidation: String? {
        guard IPv4Address(clientHost.trimmingCharacters(in: .whitespaces)) != nil else { return "Adresse IP de l’appareil invalide." }
        guard let port = UInt16(clientPortText.trimmingCharacters(in: .whitespaces)), port > 0 else { return "Port invalide." }
        guard !remoteName.trimmingCharacters(in: .whitespaces).isEmpty else { return "Indiquez le nom du fichier sur l’appareil." }
        guard !localPath.isEmpty else {
            return clientDirection == .put ? "Choisissez le fichier à envoyer." : "Choisissez où enregistrer le fichier."
        }
        if clientDirection == .put, !FileManager.default.fileExists(atPath: localPath) { return "Le fichier à envoyer n’existe plus." }
        return nil
    }

    func startClient(state: AppState) {
        guard !clientRunning else { return }
        if let problem = clientValidation {
            clientResult = (.critical, "Transfert impossible", problem)
            return
        }
        guard let host = IPv4Address(clientHost.trimmingCharacters(in: .whitespaces)),
              let port = UInt16(clientPortText.trimmingCharacters(in: .whitespaces)) else { return }
        let direction = clientDirection
        let remote = remoteName.trimmingCharacters(in: .whitespaces)
        let local = URL(fileURLWithPath: localPath)
        let options = TFTPClient.Options(blockSize: clientBlockSize, windowSize: clientWindow, timeout: clientTimeout,
                                         retries: clientRetries, mode: clientMode, useOptions: clientUseOptions)
        let name = state.devices.first { $0.ip == host }?.displayName
        var record = TFTPTransferRecord(role: .client, flow: direction == .put ? .toDevice : .fromDevice, peer: host.description,
                                        peerName: name, filename: remote, site: siteKey)
        if direction == .put {
            record.total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value
        }
        upsert(record, persist: false)
        clientRunning = true
        clientBytes = 0
        clientTotal = record.total
        clientResult = nil
        ToolStore.shared.record(command: command)
        let cancel = TFTPCancelFlag()
        clientCancel = cancel
        let id = record.id
        if isDemo {
            TFTPDemo.runClient(model: self, recordID: id)
            return
        }
        Task {
            do {
                let result = try await TFTPClient.transfer(direction, host: host, port: port, remote: remote, local: local, options: options,
                                                           progress: { bytes, total in
                                                               DispatchQueue.main.async { TFTPModel.shared.clientProgress(id: id, bytes: bytes, total: total) }
                                                           },
                                                           cancelled: { cancel.isCancelled })
                finishClient(id: id, result: result, failure: nil)
            } catch {
                let failure = (error as? TFTPFailure) ?? .local(.notDefined, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                finishClient(id: id, result: nil, failure: failure)
            }
        }
    }

    func cancelClient() {
        clientCancel.cancel()
    }

    func clientProgress(id: UUID, bytes: Int64, total: Int64?) {
        clientBytes = bytes
        if let total { clientTotal = total }
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.bytes = bytes
        if let total { record.total = total }
        record.seconds = Date().timeIntervalSince(record.date)
        upsert(record, persist: false)
    }

    func finishClient(id: UUID, result: TFTPClient.Result?, failure: TFTPFailure?) {
        clientRunning = false
        guard var record = records.first(where: { $0.id == id }) else { return }
        let target = "\(record.peerName.map { "\($0) · " } ?? "")\(record.peer)"
        if let result {
            record.status = .done
            record.bytes = result.bytes
            record.seconds = result.seconds
            record.blockSize = result.settings.blockSize
            record.windowSize = result.settings.windowSize
            record.detail = Self.optionsText(result.settings, mode: result.settings.mode)
                + (result.withoutOptions && clientUseOptions ? " · options refusées par l’appareil (RFC 1350)" : "")
            clientBytes = result.bytes
            let verb = record.flow == .toDevice ? "envoyé à" : "reçu de"
            clientResult = (.success, "Transfert réussi",
                            "«\u{00A0}\(record.filename)\u{00A0}» \(verb) \(target)\u{00A0}: \(TFTPFormat.bytes(result.bytes)) en \(ToolFormat.seconds(result.seconds)) (\(record.rateText)).")
            ToolStore.shared.record(ToolRecent(tool: .tftp, target: target,
                                               summary: "\(record.flow == .toDevice ? "Envoi" : "Réception") de \(record.filename) · \(TFTPFormat.bytes(result.bytes))",
                                               status: .ok, title: "Client TFTP"))
        } else {
            let failure = failure ?? .cancelled
            record.status = failure == .cancelled ? .cancelled : .failed
            record.reason = failure.shortLabel
            record.detail = failure.errorDescription ?? "Échec"
            record.seconds = Date().timeIntervalSince(record.date)
            clientResult = (failure == .cancelled ? .neutral : .critical, failure == .cancelled ? "Transfert annulé" : "Échec du transfert",
                            Self.advice(for: failure, record: record))
            ToolStore.shared.record(ToolRecent(tool: .tftp, target: target, summary: "\(record.filename) · \(record.detail)",
                                               status: failure == .cancelled ? .info : .failure, title: "Client TFTP"))
        }
        upsert(record, persist: true)
    }

    /// Message d'échec, avec la piste la plus probable pour un technicien.
    static func advice(for failure: TFTPFailure, record: TFTPTransferRecord) -> String {
        let base = failure.errorDescription ?? "Échec"
        switch failure {
        case .timeout:
            return base + " Vérifiez que l’appareil a un serveur TFTP actif (beaucoup de switchs n’en ont pas\u{00A0}: ce sont eux qui sont clients, utilisez alors le serveur de NetScope), son ACL et son pare-feu."
        case .remote(.fileNotFound, _):
            return base + " Vérifiez le nom exact du fichier sur l’appareil (majuscules comprises)."
        case .remote(.accessViolation, _):
            return base + " L’appareil refuse l’écriture ou la lecture de ce fichier (droits, mode lecture seule)."
        case .remote(.diskFull, _):
            return base + " Mémoire flash pleine sur l’appareil\u{00A0}: supprimez une ancienne image."
        default:
            return base
        }
    }

    // MARK: Journal

    func clearHistory() {
        records.removeAll { $0.site == siteKey && $0.status != .running }
        save()
    }

    func upsert(_ record: TFTPTransferRecord, persist: Bool) {
        records = TFTPHistory.upsert(record, into: records)
        if persist { save() }
    }

    func setDemo(records: [TFTPTransferRecord], files: [TFTPSharedFile], interfaces: [LocalInterface], firewall: TFTPFirewallStatus?) {
        self.records = records
        self.files = files
        self.interfaces = interfaces
        self.firewall = firewall
    }

    func setDemoServer(running: Bool, port: UInt16, startedAt: Date?, remaining: TimeInterval?, activeTransfers: Int) {
        isRunning = running
        listeningPort = running ? port : nil
        self.startedAt = startedAt
        self.remaining = remaining
        self.activeTransfers = activeTransfers
    }

    func setDemoClient(bytes: Int64, total: Int64?, running: Bool, result: (tone: Tone, title: String, message: String)?) {
        clientBytes = bytes
        clientTotal = total
        clientRunning = running
        clientResult = result
    }

    private func save() {
        guard !isEphemeral else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("TFTP", "Enregistrement impossible de \(url.path)\u{00A0}: \(error.localizedDescription)")
        }
    }

    private func save(_ key: String, _ value: Any) {
        defaults?.set(value, forKey: key)
    }
}

/// Drapeau d'annulation lu depuis le fil du client.
final class TFTPCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
