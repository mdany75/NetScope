import AppKit
import Foundation
import NetScopeCore

/// Période affichée par l'écran Journaux.
enum LogPeriod: String, CaseIterable, Identifiable {
    case quarter, hour, day, week, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quarter: return "15\u{00A0}min"
        case .hour: return "1\u{00A0}h"
        case .day: return "24\u{00A0}h"
        case .week: return "7\u{00A0}j"
        case .custom: return "Plage…"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .quarter: return 900
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .custom: return nil
        }
    }
}

/// Ligne du tableau des journaux : un message, ou un groupe de messages identiques.
struct LogRow: Identifiable {
    let message: LogMessage
    let count: Int
    let firstDate: Date
    /// Nom de l'appareil pour NetScope (nom saisi, Scanner, inventaire), sinon celui du message.
    let name: String
    let ref: NavDeviceRef?

    var id: UUID { message.id }

    var sortDate: Date { message.date }
    var sortName: String { SearchText.fold(name) }
    var sortIP: UInt32 { IPv4Address(message.host)?.value ?? .max }
    var sortSite: String { message.siteName }
    var sortSource: String { message.source.label }
    var sortSeverity: Int { message.severity.rawValue }
    var sortMessage: String { SearchText.fold(message.message) }
    var sortApp: String { message.app ?? "~" }
    var sortEvent: String { message.eventID ?? "~" }
    var sortCount: Int { count }
}

/// Journaux (note 43) : récepteurs Syslog et traps SNMP de ce Mac (démarrés seulement à la demande,
/// arrêt automatique réglable), journaux d'événements lus sur la FortiGate (API REST, lecture
/// seule) et journal borné enregistré dans ~/Library/Application Support/NetScope/journaux.json.
/// Chaque message reçu est rattaché au site actif au moment de la réception ; un journal de la
/// FortiGate au site de cette FortiGate (jamais un site choisi par la seule adresse IP).
///
/// Démonstration et captures : journal fictif (JournauxDemo), aucun port ouvert, rien d'envoyé ni
/// d'enregistré.
@MainActor
final class LogStore: ObservableObject {
    static let shared: LogStore = {
        let store = LogStore()
        loaded = true
        return store
    }()
    /// Vrai une fois le magasin créé (fermeture de l'app : ne pas le créer pour rien).
    private static var loaded = false

    static var isListeningIfLoaded: Bool { loaded && shared.isListening }

    /// Enregistrement synchrone à la fermeture de l'app, s'il reste des messages à écrire.
    static func saveOnQuitIfLoaded() {
        guard loaded, !shared.isDemo else { return }
        shared.stop(reason: nil)
        // Journal enregistré pas encore relu : ne pas l'écraser.
        guard shared.saveScheduled, shared.loadFinished else { return }
        try? FileManager.default.createDirectory(at: shared.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(shared.journal) { try? data.write(to: shared.url, options: .atomic) }
        shared.saveScheduled = false
    }

    // MARK: Réglages (préférences ; aucun secret)

    @Published var syslogPort: UInt16 { didSet { save("journaux.port.syslog", Int(syslogPort)) } }
    @Published var trapPort: UInt16 { didSet { save("journaux.port.traps", Int(trapPort)) } }
    @Published var syslogEnabled: Bool { didSet { save("journaux.syslog", syslogEnabled) } }
    /// Note 78 : Syslog aussi en TCP (RFC 6587), sur le même port que l'UDP.
    @Published var syslogTCPEnabled: Bool { didSet { save("journaux.syslog.tcp", syslogTCPEnabled) } }
    /// Note 78 : transfert des messages reçus vers un autre serveur Syslog (désactivé par défaut).
    @Published var forward: SyslogForwardSettings {
        didSet {
            guard forward != oldValue else { return }
            if !isDemo, let data = try? JSONEncoder().encode(forward) { UserDefaults.standard.set(data, forKey: "journaux.transfert") }
            forwardSettingsChanged()
        }
    }
    @Published var trapsEnabled: Bool { didSet { save("journaux.traps", trapsEnabled) } }
    /// Arrêt automatique des récepteurs (minutes ; 0 : jamais).
    @Published var autoStopMinutes: Int { didSet { save("journaux.arret", autoStopMinutes) } }
    /// N'accepter que les traps portant la communauté de Réglages › Identifiants (lue au Trousseau).
    @Published var checkCommunity: Bool { didSet { save("journaux.communaute", checkCommunity) } }
    @Published var retention: LogRetention {
        didSet {
            guard retention != oldValue else { return }
            if !isDemo, let data = try? JSONEncoder().encode(retention) { UserDefaults.standard.set(data, forKey: "journaux.conservation") }
            journal.prune(retention: retention, now: now)
            changed()
        }
    }
    @Published var fortiStorage: FortiLogStorage { didSet { save("journaux.forti.emplacement", fortiStorage.rawValue) } }

    static let autoStopChoices = [15, 60, 240, 480, 0]
    static let defaultSyslogPort: UInt16 = 5514
    static let defaultTrapPort: UInt16 = 1162

    // MARK: État

    @Published private(set) var journal = LogJournal()
    /// Change à chaque modification du journal (mémoire des lignes calculées).
    @Published private(set) var version = 0
    @Published private(set) var syslogListening = false
    @Published private(set) var syslogTCPListening = false
    @Published private(set) var syslogTCPError: String?
    /// Connexions TCP ouvertes par les équipements (Syslog TCP).
    @Published private(set) var tcpConnections = 0
    /// Messages Syslog reçus en TCP depuis le démarrage.
    @Published private(set) var receivedTCP = 0
    /// Transfert : compteurs et dernier incident.
    @Published private(set) var forwardStatus = SyslogForwardStatus()
    @Published private(set) var trapListening = false
    @Published private(set) var syslogError: String?
    @Published private(set) var trapError: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var stopAt: Date?
    @Published private(set) var lastStopReason: String?
    /// Messages reçus depuis le démarrage, par source.
    @Published private(set) var receivedCount: [LogSource: Int] = [:]
    /// Datagrammes écartés (trap illisible, communauté refusée, débit trop élevé), avec la dernière raison.
    @Published private(set) var rejectedCount = 0
    @Published private(set) var lastRejection: String?
    @Published private(set) var firewall: TFTPFirewallStatus?
    @Published var toast: String?

    // FortiGate
    @Published private(set) var fortiReading: Set<UUID> = []
    @Published private(set) var fortiErrors: [UUID: String] = [:]
    @Published private(set) var fortiNotes: [UUID: [String]] = [:]
    @Published private(set) var fortiLastRead: [UUID: Date] = [:]
    @Published private(set) var fortiStorageUsed: [UUID: String] = [:]
    private var fortiCalls: [UUID: [FortiCallRecord]] = [:]

    let isDemo: Bool
    /// Heure figée de la démonstration (périodes et horodatages stables).
    private(set) var demoNow: Date?
    var now: Date { demoNow ?? Date() }

    private var syslogListener: LogUDPListener?
    private var syslogTCPListener: LogTCPListener?
    private var forwarder: SyslogForwarder?
    private var trapListener: LogUDPListener?
    private let inbox = LogInbox()
    private var flushTimer: Timer?
    private var saveScheduled = false
    /// Vrai une fois le journal enregistré relu (ou absent) : rien n'est écrit avant.
    private var loadFinished = false
    /// Compte les « Vider » : un vidage pendant la lecture écarte le journal relu.
    private var clearCount = 0
    /// Accusés d'inform SNMP envoyés par adresse (fenêtre d'une seconde) : pas de réflexion massive.
    private var replyWindow: (start: Date, counts: [IPv4Address: Int]) = (Date.distantPast, [:])
    static let replyLimitPerSecond = 10
    private let url: URL
    weak var appState: AppState?

    private init() {
        let arguments = CommandLine.arguments
        let demo = arguments.contains("--demo") || arguments.contains("--snapshot")
        isDemo = demo
        let defaults = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { demo ? fallback : ((defaults.object(forKey: key) as? Int) ?? fallback) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { demo ? fallback : ((defaults.object(forKey: key) as? Bool) ?? fallback) }
        syslogPort = UInt16(clamping: int("journaux.port.syslog", Int(Self.defaultSyslogPort)))
        trapPort = UInt16(clamping: int("journaux.port.traps", Int(Self.defaultTrapPort)))
        syslogEnabled = bool("journaux.syslog", true)
        syslogTCPEnabled = bool("journaux.syslog.tcp", true)
        forward = demo ? JournauxDemo.forwardSettings : (defaults.data(forKey: "journaux.transfert").flatMap { try? JSONDecoder().decode(SyslogForwardSettings.self, from: $0) } ?? .disabled)
        trapsEnabled = bool("journaux.traps", true)
        autoStopMinutes = int("journaux.arret", 60)
        checkCommunity = bool("journaux.communaute", false)
        retention = demo ? .standard : (defaults.data(forKey: "journaux.conservation").flatMap { try? JSONDecoder().decode(LogRetention.self, from: $0) } ?? .standard)
        fortiStorage = demo ? .auto : (defaults.string(forKey: "journaux.forti.emplacement").flatMap(FortiLogStorage.init(rawValue:)) ?? .auto)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("journaux.json")
        if isDemo {
            loadFinished = true
            let demo = JournauxDemo.make()
            demoNow = demo.now
            journal = LogJournal(messages: demo.messages)
            syslogListening = demo.listening
            syslogTCPListening = demo.listening
            trapListening = demo.listening
            tcpConnections = demo.listening ? 2 : 0
            receivedTCP = demo.listening ? demo.messages.filter { $0.source == .syslog && JournauxDemo.tcpHosts.contains($0.host) }.count : 0
            forwardStatus = JournauxDemo.forwardStatus(listening: demo.listening)
            startedAt = demo.listening ? demo.now.addingTimeInterval(-42 * 60) : nil
            stopAt = demo.listening ? startedAt?.addingTimeInterval(60 * 60) : nil
            receivedCount = [.syslog: demo.messages.filter { $0.source == .syslog }.count, .trap: demo.messages.filter { $0.source == .trap }.count]
            firewall = TFTPFirewallStatus(enabled: true, blockAll: false, app: .unknown)
            fortiLastRead = demo.fortiRead
        } else {
            load()
        }
    }

    private func save(_ key: String, _ value: Any) {
        guard !isDemo else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func attach(_ state: AppState) {
        appState = state
    }

    // MARK: Récepteurs

    var isListening: Bool { syslogListening || syslogTCPListening || trapListening }
    var isSyslogListening: Bool { syslogListening || syslogTCPListening }
    func isListening(_ source: LogSource) -> Bool { source == .syslog ? isSyslogListening : (source == .trap ? trapListening : false) }
    var listeningSources: Set<LogSource> {
        var set = Set<LogSource>()
        if isSyslogListening { set.insert(.syslog) }
        if trapListening { set.insert(.trap) }
        return set
    }
    var hasFortiGateLogs: Bool { !fortiLastRead.isEmpty }

    /// Démarre les récepteurs choisis (Syslog, traps) sur toutes les interfaces.
    func start() {
        guard !isDemo else {
            syslogListening = syslogEnabled
            syslogTCPListening = syslogEnabled && syslogTCPEnabled
            trapListening = trapsEnabled
            startedAt = now
            scheduleAutoStop()
            return
        }
        stop(reason: nil)
        syslogError = nil
        syslogTCPError = nil
        trapError = nil
        lastStopReason = nil
        receivedCount = [:]
        receivedTCP = 0
        tcpConnections = 0
        forwardStatus = SyslogForwardStatus()
        rejectedCount = 0
        lastRejection = nil
        let inbox = self.inbox
        if syslogEnabled {
            let listener = LogUDPListener(port: syslogPort, name: "Syslog", handler: { datagram in
                inbox.add(datagram, kind: .syslog)
            }, stopped: { reason in
                guard let reason else { return }
                Task { @MainActor in LogStore.shared.listenerStopped(.syslog, reason: reason) }
            })
            do {
                try listener.start()
                syslogListener = listener
                syslogListening = true
            } catch {
                syslogError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if syslogTCPEnabled {
                let tcp = LogTCPListener(port: syslogPort, name: "Syslog TCP", handler: { datagram in
                    inbox.add(datagram, kind: .syslog, tcp: true)
                }, stopped: { reason in
                    guard let reason else { return }
                    Task { @MainActor in LogStore.shared.tcpListenerStopped(reason: reason) }
                })
                do {
                    try tcp.start()
                    syslogTCPListener = tcp
                    syslogTCPListening = true
                } catch {
                    syslogTCPError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        if trapsEnabled {
            let community = checkCommunity ? RegSNMPCredentials.load()?.community : nil
            if checkCommunity, community?.isEmpty ?? true {
                trapError = "Aucune communauté SNMP dans Réglages › Identifiants\u{00A0}: toutes les traps sont acceptées."
            }
            inbox.setCommunity(community)
            let listener = LogUDPListener(port: trapPort, name: "Traps", handler: { datagram in
                inbox.add(datagram, kind: .trap)
            }, stopped: { reason in
                guard let reason else { return }
                Task { @MainActor in LogStore.shared.listenerStopped(.trap, reason: reason) }
            })
            do {
                try listener.start()
                trapListener = listener
                trapListening = true
            } catch {
                trapError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        guard isListening else { return }
        startForwarder()
        startedAt = Date()
        scheduleAutoStop()
        startFlushTimer()
        Task { firewall = await TFTPFirewallStatus.read(appPath: Bundle.main.bundlePath) }
    }

    /// Arrête les récepteurs ; `reason` : arrêt automatique ou incident, montré dans le panneau.
    func stop(reason: String? = nil) {
        if isDemo {
            syslogListening = false
            syslogTCPListening = false
            trapListening = false
            stopAt = nil
            lastStopReason = reason
            return
        }
        // Derniers datagrammes d'abord, sockets encore ouverts : les informs reçoivent leur accusé.
        flush()
        syslogListener?.stop()
        syslogTCPListener?.stop()
        trapListener?.stop()
        syslogListener = nil
        syslogTCPListener = nil
        trapListener = nil
        if let forwarder {
            forwardStatus = forwarder.currentStatus
            forwarder.stop()
        }
        forwarder = nil
        let wasListening = isListening
        syslogListening = false
        syslogTCPListening = false
        trapListening = false
        tcpConnections = 0
        stopAt = nil
        if wasListening { lastStopReason = reason }
    }

    private func listenerStopped(_ source: LogSource, reason: String) {
        if source == .syslog {
            syslogListening = false
            syslogListener = nil
            syslogError = reason
        } else {
            trapListening = false
            trapListener = nil
            trapError = reason
        }
    }

    private func tcpListenerStopped(reason: String) {
        syslogTCPListening = false
        syslogTCPListener = nil
        syslogTCPError = reason
        tcpConnections = 0
    }

    // MARK: Transfert (note 78)

    /// Ports où ce Mac écoute (pas de transfert en boucle vers soi-même).
    private var listeningPorts: [(SyslogTransport, UInt16)] {
        var list: [(SyslogTransport, UInt16)] = []
        if syslogEnabled { list.append((.udp, syslogPort)) }
        if syslogEnabled, syslogTCPEnabled { list.append((.tcp, syslogPort)) }
        return list
    }

    /// Réglage du transfert à corriger, en clair (nil : prêt ou désactivé).
    var forwardProblem: String? {
        guard forward.enabled else { return nil }
        return forward.problem(listening: listeningPorts)
    }

    /// Le transfert tourne (réception démarrée, réglages valides).
    var isForwarding: Bool { isDemo ? (isListening && forward.enabled) : forwarder != nil }

    private func startForwarder() {
        forwarder?.stop()
        forwarder = nil
        guard !isDemo, forward.enabled, forwardProblem == nil else { return }
        forwarder = SyslogForwarder(settings: forward)
    }

    private func forwardSettingsChanged() {
        if isDemo {
            forwardStatus = JournauxDemo.forwardStatus(listening: isListening && forward.enabled)
            return
        }
        guard isListening else { return }
        if let forwarder { forwardStatus = forwarder.currentStatus }
        startForwarder()
    }

    private func scheduleAutoStop() {
        stopAt = autoStopMinutes > 0 ? (startedAt ?? now).addingTimeInterval(TimeInterval(autoStopMinutes * 60)) : nil
    }

    /// Le délai d'arrêt change pendant l'écoute : il repart de maintenant.
    func autoStopChanged() {
        guard isListening else { return }
        stopAt = autoStopMinutes > 0 ? now.addingTimeInterval(TimeInterval(autoStopMinutes * 60)) : nil
    }

    private func startFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in LogStore.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func tick() {
        flush()
        if let syslogTCPListener { tcpConnections = syslogTCPListener.connections }
        if let forwarder {
            let status = forwarder.currentStatus
            if status != forwardStatus { forwardStatus = status }
        }
        if let stopAt, Date() >= stopAt {
            stop(reason: "Arrêté automatiquement après \(autoStopMinutes >= 60 ? "\(autoStopMinutes / 60)\u{00A0}h" : "\(autoStopMinutes)\u{00A0}min") d’écoute.")
        }
        if !isListening, inbox.isEmpty {
            flushTimer?.invalidate()
            flushTimer = nil
        }
    }

    /// Décode les datagrammes reçus et les ajoute au journal (site actif au moment de la réception).
    private func flush() {
        let batch = inbox.take()
        guard !batch.datagrams.isEmpty || batch.dropped > 0 else { return }
        let siteKey = SiteModel.shared.activeKey
        let siteName = SiteModel.shared.activeName
        var messages: [LogMessage] = []
        var forwarded: [[UInt8]] = []
        let forwarding = forwarder?.settings
        for (datagram, kind, viaTCP) in batch.datagrams {
            let outcome = kind == .syslog ? LogDecoder.syslog(datagram) : LogDecoder.trap(datagram, community: batch.community)
            switch outcome {
            case .message(let message, let reply):
                messages.append(message.attached(siteKey: siteKey, siteName: siteName))
                receivedCount[message.source, default: 0] += 1
                if viaTCP { receivedTCP += 1 }
                if let forwarding, forwarding.accepts(message) {
                    forwarded.append(forwarding.payload(for: message, original: message.source == .syslog ? datagram.bytes : nil))
                }
                if let reply, allowReply(to: datagram.from) { trapListener?.reply(reply, to: datagram.from, port: datagram.fromPort) }
            case .rejected(let reason):
                rejectedCount += 1
                lastRejection = reason
            }
        }
        if batch.dropped > 0 {
            rejectedCount += batch.dropped
            lastRejection = "\(batch.dropped) message\(batch.dropped > 1 ? "s" : "") ignoré\(batch.dropped > 1 ? "s" : "")\u{00A0}: débit trop élevé (plus de \(LogInbox.limit) en une demi-seconde)."
        }
        if !forwarded.isEmpty { forwarder?.enqueue(forwarded) }
        guard !messages.isEmpty else { return }
        journal.append(messages, retention: retention, now: Date())
        changed()
    }

    /// Au plus `replyLimitPerSecond` accusés par seconde vers une même adresse (adresse usurpée).
    private func allowReply(to address: IPv4Address) -> Bool {
        let date = Date()
        if date.timeIntervalSince(replyWindow.start) >= 1 { replyWindow = (date, [:]) }
        let count = replyWindow.counts[address, default: 0]
        guard count < Self.replyLimitPerSecond else { return false }
        replyWindow.counts[address] = count + 1
        return true
    }

    /// Envoie un message Syslog et une trap d'essai à ce Mac (127.0.0.1 seulement).
    func sendTest() {
        if isDemo {
            toast = "Démonstration\u{00A0}: rien n’est envoyé."
            return
        }
        var sent: [String] = []
        if syslogListening {
            let bytes = SyslogParser.encode5424(severity: .notice, date: Date(), hostname: Host.current().localizedName ?? "NetScope",
                                                app: "NetScope", msgID: "ESSAI", message: "Message d’essai de NetScope\u{00A0}: le récepteur Syslog fonctionne.")
            if LogUDPListener.sendToSelf(bytes, port: syslogListener?.boundPort ?? syslogPort) { sent.append("un message Syslog (UDP)") }
        }
        if syslogTCPListening {
            let bytes = SyslogParser.encode5424(severity: .notice, date: Date(), hostname: Host.current().localizedName ?? "NetScope",
                                                app: "NetScope", msgID: "ESSAI", message: "Message d’essai de NetScope\u{00A0}: le récepteur Syslog TCP fonctionne.")
            if LogTCPListener.sendToSelf(SyslogFrameDecoder.octetCounted(bytes), port: syslogTCPListener?.boundPort ?? syslogPort) { sent.append("un message Syslog (TCP)") }
        }
        if trapListening {
            let community = checkCommunity ? (RegSNMPCredentials.load()?.community ?? "") : "netscope"
            let bytes = SNMPTrapDecoder.encodeV2(community: community, trapOID: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.100.1.3.0.999"),
                                                 uptime: UInt32(ProcessInfo.processInfo.systemUptime * 100) % UInt32.max,
                                                 varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.2.1.1.5.0"),
                                                                        value: .octetString(Array("NetScope".utf8)))])
            if LogUDPListener.sendToSelf(bytes, port: trapListener?.boundPort ?? trapPort) { sent.append("une trap") }
        }
        toast = sent.isEmpty ? "Démarrez d’abord la réception." : "Essai envoyé à ce Mac (127.0.0.1)\u{00A0}: " + sent.joined(separator: " et ") + "."
    }

    // MARK: Journal

    private func changed() {
        version &+= 1
        scheduleSave()
    }

    func clear(siteKeys: Set<String>?) {
        journal.removeAll(siteKeys: siteKeys)
        clearCount += 1
        changed()
    }

    /// Messages récents pour les sondes de la Surveillance.
    func recentForMonitoring(seconds: TimeInterval) -> [LogMessage] {
        Array(journal.messages(since: now.addingTimeInterval(-seconds)))
    }

    private func load() {
        let url = self.url
        let clears = clearCount
        Task.detached(priority: .utility) {
            var loaded: LogJournal?
            var unreadable: String?
            if let data = try? Data(contentsOf: url) {
                loaded = try? JSONDecoder().decode(LogJournal.self, from: data)
                if loaded == nil {
                    // Illisible : mis de côté avant toute sauvegarde, pour ne pas l'écraser.
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let aside = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".illisible-" + stamp)
                    try? FileManager.default.moveItem(at: url, to: aside)
                    unreadable = aside.lastPathComponent
                }
            }
            let result = loaded
            let asideName = unreadable
            await MainActor.run {
                let store = LogStore.shared
                store.loadFinished = true
                if let asideName {
                    store.toast = "Journal enregistré illisible\u{00A0}: mis de côté sous «\u{00A0}\(asideName)\u{00A0}», un nouveau journal commence."
                }
                // Vidé pendant la lecture : le journal relu n'est pas remis.
                if let result, store.clearCount == clears {
                    // Messages reçus pendant la lecture : gardés, mêlés au journal enregistré.
                    var merged = result
                    merged.append(store.journal.messages, retention: store.retention, now: Date())
                    merged.prune(retention: store.retention, now: Date())
                    store.journal = merged
                    store.version &+= 1
                }
                if store.saveScheduled { store.saveScheduled = false; store.scheduleSave() }
            }
        }
    }

    private func scheduleSave() {
        guard !isDemo, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
    }

    func saveNow() {
        guard loadFinished else { return }
        saveScheduled = false
        guard !isDemo else { return }
        let snapshot = journal
        let url = self.url
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Lignes affichées

    private var rowsMemo: (key: String, rows: [LogRow])?
    private var nameMemo: [String: (String, NavDeviceRef?)] = [:]
    private var nameMemoVersion: Int?

    /// Nom et appareil d'un message : Scanner (site actif), sinon inventaire du site du message.
    func device(for message: LogMessage) -> (name: String, ref: NavDeviceRef?) {
        let key = message.siteKey + "|" + message.host
        if let known = nameMemo[key] { return known }
        var result: (String, NavDeviceRef?) = (message.deviceLabel, nil)
        if let ip = IPv4Address(message.host) {
            if message.siteKey == SiteModel.shared.activeKey, let device = appState?.devices.first(where: { $0.ip == ip }) {
                result = (device.displayName, NavDeviceRef(device, siteKey: message.siteKey))
            } else if let record = InvModel.shared.inventory(for: message.siteKey).record(forIP: ip) {
                result = (record.displayName, NavDeviceRef(record, siteKey: message.siteKey))
            } else {
                result = (message.deviceLabel, NavDeviceRef(ip: message.host, name: message.deviceLabel, siteKey: message.siteKey))
            }
        }
        nameMemo[key] = result
        return result
    }

    /// Noms des appareils par adresse, pour la recherche, l'export et « Comprendre une coupure ».
    func names(for messages: [LogMessage]) -> [String: String] {
        var map: [String: String] = [:]
        for m in messages where map[m.host] == nil { map[m.host] = device(for: m).name }
        return map
    }

    func rows(filter: LogFilter, search: SearchQuery, grouped: Bool) -> [LogRow] {
        // Noms : à refaire si les appareils du Scanner, le site actif ou l'inventaire changent.
        var hasher = Hasher()
        hasher.combine(SiteModel.shared.activeKey)
        hasher.combine(InvModel.shared.inventory(for: SiteModel.shared.activeKey).records.count)
        for device in appState?.devices ?? [] {
            hasher.combine(device.ip.value)
            hasher.combine(device.displayName)
        }
        let devicesVersion = hasher.finalize()
        if nameMemoVersion != devicesVersion {
            nameMemo = [:]
            nameMemoVersion = devicesVersion
        }
        // Bornes arrondies à 5 s : une période relative (« 1 h ») recalculée à chaque rendu garde la même clé.
        func rounded(_ date: Date?) -> String { date.map { String(Int(($0.timeIntervalSince1970 / 5).rounded(.down))) } ?? "" }
        let key = [String(version), rounded(filter.from), rounded(filter.to),
                   String(filter.minimumSeverity.rawValue), filter.sources.map(\.rawValue).sorted().joined(separator: ","),
                   filter.siteKeys?.sorted().joined(separator: ",") ?? "*", search.text, grouped ? "g" : "", SiteModel.shared.activeKey].joined(separator: "|")
        if let memo = rowsMemo, memo.key == key { return memo.rows }
        let base = filter.apply(journal.messages)
        let names = self.names(for: base)
        let found = search.isEmpty ? base : base.filter { search.matches(LogSearchItem($0, deviceName: names[$0.host])) }
        let rows: [LogRow]
        if grouped {
            rows = LogAnalysis.group(found).map { group in
                let device = device(for: group.latest)
                return LogRow(message: group.latest, count: group.count, firstDate: group.firstDate, name: device.name, ref: device.ref)
            }
        } else {
            rows = found.map { m in
                let device = device(for: m)
                return LogRow(message: m, count: 1, firstDate: m.date, name: device.name, ref: device.ref)
            }
        }
        rowsMemo = (key, rows)
        return rows
    }

    /// « Comprendre une coupure » : messages de tous les appareils des sites montrés autour d'une heure.
    func outage(around date: Date, span: TimeInterval, siteKeys: Set<String>?) -> LogAnalysis.OutageReport {
        let messages = siteKeys.map { keys in journal.messages.filter { keys.contains($0.siteKey) } } ?? journal.messages
        return LogAnalysis.outage(around: date, span: span, messages: messages, names: names(for: messages))
    }

    // MARK: FortiGate (API REST, lecture seule)

    var isReadingFortiGate: Bool { !fortiReading.isEmpty }

    /// FortiGate des sites montrés (celles du site enregistré, sinon celles choisies pour les switchs).
    func controllerIDs(forKeys keys: [String]) -> [UUID] {
        var seen = Set<UUID>()
        return keys.flatMap { key -> [UUID] in
            if let site = SiteModel.shared.site(forKey: key) { return site.fortiGateIDs }
            return key == SiteModel.shared.activeKey ? FortiGateStore.shared.selection.controllerIDs : []
        }.filter { seen.insert($0).inserted }
    }

    func siteKey(forController id: UUID) -> String {
        SiteModel.shared.sites.first { $0.fortiGateIDs.contains(id) }.map { SiteFiles.key(for: $0.id) } ?? SiteModel.shared.activeKey
    }

    func canReadFortiGate(keys: [String]) -> Bool {
        let fortigate = FortiGateStore.shared
        return fortigate.isEnabled && !controllerIDs(forKeys: keys).isEmpty && (fortigate.isReady || isDemo)
    }

    /// Lit les journaux d'événements des FortiGate des sites montrés, depuis `since`.
    func readFortiGate(keys: [String], since: Date, until: Date?) {
        let ids = controllerIDs(forKeys: keys).filter { !fortiReading.contains($0) }
        guard !ids.isEmpty else { return }
        fortiReading.formUnion(ids)
        let options = FortiLogReadOptions(since: since, until: until, minimumSeverity: .info, storage: fortiStorage)
        Task { [weak self] in
            guard let self else { return }
            defer { self.fortiReading.subtract(ids) }
            if self.isDemo {
                try? await Task.sleep(nanoseconds: RegEnvironment.isSnapshot ? 0 : 400_000_000)
                for id in ids {
                    let key = self.siteKey(forController: id)
                    let messages = JournauxDemo.fortiGateLogs(siteKey: key, siteName: SiteModel.shared.name(forKey: key), now: self.now)
                    self.journal.append(messages, retention: self.retention, now: self.now)
                    self.fortiLastRead[id] = self.now
                    self.fortiStorageUsed[id] = "memory"
                    self.fortiErrors[id] = nil
                }
                self.changed()
                self.toast = "Journaux de la FortiGate relus (démonstration)."
                return
            }
            let fortigate = FortiGateStore.shared
            guard fortigate.isEnabled else { return }
            let picks = ids.map { FortiControllerSelection.Pick(controllerID: $0, site: fortigate.controller($0)?.displayName ?? "FortiGate", reason: .activeSite) }
            let targets = await fortigate.wifiTargets(for: FortiControllerSelection(picks: picks))
            for (id, reason) in targets.blocked { self.fortiErrors[id] = reason }
            let jobs = targets.ready.map { LogJob(id: $0.0.id, config: $0.0.config, token: $0.1, options: options) }
            let results = await FortiMulti.parallel(jobs, limit: FortiMulti.concurrentReads) { await LogStore.performRead($0) }
            var added = 0
            for (job, result) in zip(jobs, results) {
                let key = self.siteKey(forController: job.id)
                switch result {
                case .success(let report):
                    let messages = report.messages.map { $0.attached(siteKey: key, siteName: SiteModel.shared.name(forKey: key)) }
                    added += self.journal.append(messages, retention: self.retention, now: Date())
                    self.fortiCalls[job.id] = report.calls
                    self.fortiNotes[job.id] = report.notes
                    self.fortiStorageUsed[job.id] = report.storage
                    self.fortiLastRead[job.id] = report.readAt
                    self.fortiErrors[job.id] = nil
                case .failure(let message, let calls):
                    self.fortiErrors[job.id] = message
                    self.fortiCalls[job.id] = calls
                }
            }
            self.changed()
            if !jobs.isEmpty {
                self.toast = added > 0 ? "\(LogFormat.count(added, "nouveau message", "nouveaux messages")) lu\(added > 1 ? "s" : "") sur la FortiGate."
                    : "Aucun nouveau message sur la FortiGate pour cette période."
            }
        }
    }

    struct LogJob: Sendable {
        var id: UUID
        var config: FortiGateConfig
        var token: String
        var options: FortiLogReadOptions
    }

    enum LogResult: Sendable {
        case success(FortiLogReadReport)
        case failure(String, [FortiCallRecord])
    }

    nonisolated static func performRead(_ job: LogJob) async -> LogResult {
        let transport = FortiURLSessionTransport(config: job.config, token: job.token)
        let reader = FortiGateReader(transport: transport, tokenForRedaction: job.token)
        do {
            return .success(try await reader.readLogsKeepingCalls(job.options, host: job.config.cleanHost))
        } catch let failure as FortiReadFailure {
            return .failure(FortiRedact.clean(failure.error.logDescription, token: job.token), failure.calls)
        } catch let error as FortiGateError {
            return .failure(FortiRedact.clean(error.logDescription, token: job.token), [])
        } catch {
            return .failure("Lecture des journaux impossible.", [])
        }
    }

    /// Réponses brutes des journaux d'une FortiGate (diagnostic de FortiGateStore), sans le jeton.
    func diagnosticCalls(_ id: UUID) -> [FortiCallRecord] { fortiCalls[id] ?? [] }

    // MARK: Export

    func csv(_ rows: [LogRow], grouped: Bool) -> String {
        let messages = rows.map(\.message)
        var names: [String: String] = [:]
        for row in rows { names[row.message.host] = row.name }
        return LogAnalysis.csv(messages, names: names, counts: grouped ? Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.count) }) : [:])
    }
}

/// Boîte de réception partagée entre les fils d'écoute et l'app : datagrammes bruts, décodés par
/// lots sur le fil principal. Au-delà de `limit` par lot, les datagrammes sont comptés puis jetés.
final class LogInbox: @unchecked Sendable {
    static let limit = 2_000
    private let lock = NSLock()
    private var items: [(LogDatagram, LogSource, Bool)] = []
    private var dropped = 0
    private var community: String?

    /// `tcp` : message reçu par le récepteur Syslog TCP (note 78).
    func add(_ datagram: LogDatagram, kind: LogSource, tcp: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if items.count >= Self.limit { dropped += 1; return }
        items.append((datagram, kind, tcp))
    }

    func setCommunity(_ value: String?) {
        lock.lock()
        community = value
        lock.unlock()
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }

    func take() -> (datagrams: [(LogDatagram, LogSource, Bool)], dropped: Int, community: String?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (items, dropped, community)
        items.removeAll(keepingCapacity: true)
        dropped = 0
        return result
    }
}
