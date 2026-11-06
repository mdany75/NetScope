import Charts
import NetScopeCore
import SwiftUI

/// Note 6 (suite, 0.26.2) : onglet « Serveur RustDesk » d'Accès distant. Tableau de bord du
/// serveur RustDesk Server OSS (hbbs + hbbr), lu en lecture seule par une connexion SSH :
/// tuiles, graphe local, sessions relayées en cours, demandes de connexion récentes, état du serveur.
struct RustDeskServerDashboard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RemoteModel
    @ObservedObject private var server = RustDeskServerModel.shared
    @ObservedObject private var watch = RustDeskServerWatchModel.shared

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !server.settings.hasAccount {
                    EmptyState(systemImage: "server.rack", title: "Compte SSH du serveur à choisir",
                               message: "Le tableau de bord lit l’état de hbbs et de hbbr par SSH, en lecture seule. Choisissez une connexion SSH du carnet ou saisissez «\u{00A0}utilisateur@hôte\u{00A0}» dans Réglages › RustDesk.") {
                        Button("Ouvrir Réglages › RustDesk") { openSettings() }.buttonStyle(.secondary)
                    }
                    .frame(height: 240)
                } else {
                    if let error = server.error { errorBanner(error) }
                    if let status = server.status {
                        content(status)
                            .opacity(server.error == nil ? 1 : 0.55)
                    } else if server.error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Lecture du serveur…").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .onAppear {
            if server.status == nil, server.error == nil, server.settings.hasAccount { server.refresh() }
            // Captures : NETSCOPE_RUSTDESK_DEFILER=maj (mises à jour, clé, suspects) ou =journaux (historique, journaux).
            guard CommandLine.arguments.contains("--snapshot"),
                  let anchor = ProcessInfo.processInfo.environment["NETSCOPE_RUSTDESK_DEFILER"] else { return }
            DispatchQueue.main.async { proxy.scrollTo("rd-" + anchor, anchor: .top) }
        }
        }
        .sheet(item: $watch.editing) { target in
            RustDeskNoteSheet(target: target, watch: watch)
        }
        .sheet(item: $watch.associating) { request in
            RustDeskAssociationSheet(request: request, watch: watch)
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(RemoteProtocol.rustdesk.tint)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(RemoteProtocol.rustdesk.soft))
            VStack(alignment: .leading, spacing: 2) {
                Text("Serveur RustDesk").font(Theme.panelTitle)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { readTime; actions }.fixedSize()
                VStack(alignment: .trailing, spacing: 4) { actions; readTime }.fixedSize()
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = [server.accountLabel ?? "Lecture seule par SSH"]
        if let status = server.status {
            // Espaces insécables : la coupure de ligne ne tombe jamais au milieu d'un nom.
            if !status.system.isEmpty { parts.append(status.system.replacingOccurrences(of: " ", with: "\u{00A0}")) }
            if let version = status.version { parts.append("RustDesk\u{00A0}Server\u{00A0}\(version)") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var readTime: some View {
        if let copied = server.copied {
            Label(copied, systemImage: "checkmark").font(Theme.caption).foregroundStyle(Theme.success)
        } else if let status = server.status {
            Text("Lu à \(RustDeskServerDashboard.clock(status.readAt)) · toutes les \(RustDeskDashboardSettings.refreshLabel(server.settings.refreshSeconds))")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                server.copyCommand()
            } label: {
                Label("Copier la commande", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .disabled(server.accountLabel == nil)
            .help(copyHelp)
            Button {
                server.refresh()
            } label: {
                if server.reading {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Lecture…")
                    }
                } else {
                    Label("Actualiser", systemImage: "arrow.clockwise").labelStyle(RemoteCompactLabelStyle())
                }
            }
            .buttonStyle(RemoteSmallButtonStyle(primary: true))
            .disabled(server.reading || !server.settings.hasAccount)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var copyHelp: String {
        guard let account = try? server.resolvedAccount().get() else { return "Choisissez d’abord le compte SSH du serveur" }
        return "Copie la commande équivalente, à coller dans Terminal (script de lecture compris, aucun secret)\u{00A0}:\n"
            + RustDeskServerSSH.displayCommand(account)
    }

    private func openSettings() {
        RegNavigation.shared.section = .rustdesk
        state.open(.reglages)
    }

    // MARK: Erreur

    private func errorBanner(_ error: RustDeskServerReadError) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.kind == .account ? "person.crop.circle.badge.questionmark"
                  : error.kind == .unknownHostKey ? "key.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(error.kind == .account || error.kind == .unknownHostKey ? Theme.warning : Theme.critical)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(error.detail).font(error.fingerprint == nil ? Theme.small : Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error.advice).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if server.status != nil {
                    Text("Valeurs de la dernière lecture réussie, grisées ci-dessous.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 4)
            if error.kind == .account {
                Button("Réglages") { openSettings() }.buttonStyle(RemoteSmallButtonStyle())
            } else if error.kind == .unknownHostKey {
                Button("Accepter") { server.acceptHostKey() }
                    .buttonStyle(RemoteSmallButtonStyle(primary: true))
                    .disabled(server.reading)
                    .help("Ajoute cette empreinte à ~/.ssh/known_hosts et relance la lecture (le mot de passe n’est envoyé qu’après)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(error.kind == .account || error.kind == .unknownHostKey ? Theme.warningSoft : Theme.criticalSoft))
    }

    // MARK: Contenu

    @ViewBuilder private func content(_ status: RustDeskServerStatus) -> some View {
        let book = watch.book
        ForEach(status.notices) { finding in
            noticeBanner(finding)
        }
        if RustDeskServerAlerts.backupDue(last: watch.lastBackup, now: status.now) {
            noticeBanner(RustDeskFinding(.warning, "Aucune sauvegarde récente de la clé et de la base",
                                         watch.lastBackup.map { "Dernière copie chiffrée sur ce Mac \(RemoteFormat.relative($0))." }
                                             ?? "Sans copie, perdre le serveur oblige à reconfigurer la clé sur tous les postes."))
        }
        tiles(status)
        RustDeskServerChart(samples: RustDeskServerSamples.window(server.samples, hours: 6, now: status.readAt), now: status.readAt)
        Panel {
            if status.relayConsole == .ok {
                RustDeskRelayTable(rows: RustDeskRelayRow.rows(status, book: book), watch: watch)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Sessions relayées en cours")
                    Text("Inconnues\u{00A0}: la console de hbbr (127.0.0.1:\(String(RustDeskConsoleCommand.relayPort))) n’a pas répondu à cette lecture.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                if status.idConsole != .ok {
                    SectionHeader("Demandes de connexion récentes")
                    Text("Inconnues\u{00A0}: la console de hbbs (127.0.0.1:\(String(RustDeskConsoleCommand.idPort))) n’a pas répondu à cette lecture.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else if !status.punchSupported {
                    SectionHeader("Demandes de connexion récentes")
                    Text("Non disponible\u{00A0}: ce hbbs ne connaît pas la commande «\u{00A0}pr\u{00A0}». Mettez l’image rustdesk/rustdesk-server à jour.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    RustDeskRequestTable(rows: RustDeskRequestRow.rows(status, book: book, site: watch.probableSite), total: status.punchTotal, watch: watch)
                }
            }
        }
        RustDeskUpdatesPanel(status: status, watch: watch).id("rd-maj")
        RustDeskKeyBackupPanel(status: status, watch: watch, server: server)
        RustDeskSuspiciousPanel(events: watch.suspicious(status), watch: watch)
        RustDeskHistoryPanel(watch: watch).id("rd-journaux")
        RustDeskLogsPanel(watch: watch)
        serverPanel(status)
        RustDeskAlertsPanel(watch: watch)
        Text("Une session pair-à-pair (directe) ne passe plus par le serveur une fois établie\u{00A0}: seules les sessions relayées par hbbr apparaissent «\u{00A0}en cours\u{00A0}». Les demandes de connexion montrent toutes les tentatives, relayées ou directes, depuis le dernier démarrage de hbbs (liste gardée en mémoire). Le poste est nommé par son nom donné ici, le carnet ou sa fiche d’inventaire (clic droit\u{00A0}: se connecter, nommer, associer, ouvrir la fiche).")
            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func noticeBanner(_ finding: RustDeskFinding) -> some View {
        let tone: Tone = finding.level == .error ? .critical : finding.level == .warning ? .warning : .neutral
        return HStack(alignment: .top, spacing: 10) {
            RustDeskLevelIcon(level: finding.level).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }

    // MARK: Tuiles

    private func tiles(_ status: RustDeskServerStatus) -> some View {
        let day = status.punchCount()
        let relayed = RustDeskServerCorrelation.relayedRequestIDs(sessions: status.relaySessions, requests: status.punchRequests, now: status.now).count
        let peak = status.relaySessions.map(\.maxKbps).max()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4), alignment: .leading, spacing: 10) {
            RustDeskServerTile(title: "Sessions relayées", value: status.relayConsole == .ok ? "\(status.relaySessions.count)" : "—",
                               detail: status.relayConsole == .ok ? "en cours, par hbbr" : "console hbbr non lue",
                               tone: status.relayConsole == .ok ? nil : .warning)
            RustDeskServerTile(title: "Débit relayé", value: status.relayConsole == .ok ? RustDeskServerFormat.kbps(status.currentRelayKbps) : "—",
                               detail: status.relayConsole == .ok ? (peak.map { "actuel · pointe \(RustDeskServerFormat.kbps($0))" } ?? "actuel")
                                   : "console hbbr non lue",
                               tone: status.relayConsole == .ok ? nil : .warning)
            requestsTile(status, day: day, relayed: relayed)
            RustDeskServerTile(title: "Postes enregistrés", value: status.peers.value.map(String.init) ?? "—",
                               detail: status.peers.shortExplanation)
                .help(status.peers.explanation)
            processTile("hbbs", process: status.hbbs, container: status.containers.first { $0.name.contains("hbbs") },
                        consoleAnswered: status.idConsole.isOK)
            processTile("hbbr", process: status.hbbr, container: status.containers.first { $0.name.contains("hbbr") },
                        consoleAnswered: status.relayConsole.isOK)
            diskTile(status.disk)
            healthTiles(status)
        }
    }

    /// Note 87 : durée de fonctionnement, processeur, mémoire, redémarrages de hbbs et hbbr.
    @ViewBuilder private func healthTiles(_ status: RustDeskServerStatus) -> some View {
        let health = status.health
        let load = (health?.load ?? []).map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") }
        RustDeskServerTile(title: "En marche depuis", value: health?.uptimeSeconds.map { RustDeskServerFormat.duration($0) } ?? "—",
                           detail: load.isEmpty ? "système" : "charge " + load.joined(separator: " · "))
        RustDeskServerTile(title: "Processeur", value: health?.cpuPercent.map { "\(Int($0.rounded()))\u{00A0}%" } ?? "—",
                           detail: health?.cpus.map { "\($0) cœur\($0 > 1 ? "s" : "") · mesuré sur 1\u{00A0}s" } ?? "non lu",
                           tone: (health?.cpuPercent ?? 0) >= 90 ? .warning : nil, fraction: health?.cpuPercent.map { $0 / 100 })
        RustDeskServerTile(title: "Mémoire", value: health?.memoryUsedFraction.map { "\(Int(($0 * 100).rounded()))\u{00A0}%" } ?? "—",
                           detail: health?.memoryAvailableKB.map { "\(RustDeskServerFormat.kilobytes($0)) disponibles" } ?? "non lue",
                           tone: (health?.memoryUsedFraction ?? 0) >= 0.9 ? .warning : nil, fraction: health?.memoryUsedFraction)
        let inspected = watch.detail?.containers ?? []
        let details = inspected.isEmpty ? status.containerDetails : inspected
        let restarts = details.reduce(0) { $0 + $1.restartCount }
        RustDeskServerTile(title: "Redémarrages", value: details.isEmpty ? "—" : "\(restarts)",
                           detail: details.isEmpty ? "conteneurs non inspectés" : details.map { "\($0.name) \($0.restartCount)" }.joined(separator: " · "),
                           tone: restarts > 0 ? .warning : nil)
    }

    /// Demandes des dernières 24 h : console hbbs non lue, hbbs sans « pr », ou nombre lu.
    private func requestsTile(_ status: RustDeskServerStatus, day: (count: Int, atLeast: Bool), relayed: Int) -> some View {
        if status.idConsole != .ok {
            return RustDeskServerTile(title: "Demandes · 24 h", value: "—", detail: "console hbbs non lue", tone: .warning)
        }
        if !status.punchSupported {
            return RustDeskServerTile(title: "Demandes · 24 h", value: "—", detail: "hbbs sans «\u{00A0}pr\u{00A0}»")
        }
        return RustDeskServerTile(title: "Demandes · 24 h", value: day.atLeast ? "\(day.count)+" : "\(day.count)",
                                  detail: relayed > 0 ? "dont \(relayed) relayée\(relayed > 1 ? "s" : "") en cours" : "relayées ou directes")
    }

    /// `consoleAnswered` : la console du service a répondu (en marche même si ps ne voit pas le processus).
    private func processTile(_ name: String, process: RustDeskServerProcess?, container: RustDeskContainer?,
                             consoleAnswered: Bool) -> some View {
        let running = process != nil || container?.isRunning == true || consoleAnswered
        let detail: String
        if let process {
            detail = "depuis \(RustDeskServerFormat.duration(process.seconds)) · PID \(process.pid)"
        } else if let container {
            detail = RustDeskServerFormat.dockerStatus(container.status)
        } else if consoleAnswered {
            detail = "processus non visible par ps"
        } else {
            detail = "processus absent"
        }
        return RustDeskServerTile(title: name == "hbbs" ? "hbbs · serveur d’ID" : "hbbr · relais", value: running ? "En marche" : "Arrêté",
                                  detail: detail, tone: running ? .success : .critical, dot: true)
    }

    private func diskTile(_ disk: RustDeskDiskUsage?) -> some View {
        guard let disk else {
            return RustDeskServerTile(title: "Disque", value: "—", detail: "df non lu")
        }
        let percent = Int((disk.usedFraction * 100).rounded())
        // Le point de montage reste dans le détail : le titre est mis en majuscules (« /srv/data » ≠ « /SRV/DATA »).
        return RustDeskServerTile(title: "Disque", value: "\(percent)\u{00A0}%",
                                  detail: "\(disk.mount) · \(RustDeskServerFormat.kilobytes(disk.availableKB)) libres"
                                      + (disk.dataKB.map { " · data \(RustDeskServerFormat.kilobytes($0))" } ?? ""),
                                  tone: disk.usedFraction >= 0.9 ? .warning : nil, fraction: disk.usedFraction)
    }

    // MARK: Serveur

    private func serverPanel(_ status: RustDeskServerStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Serveur")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow(key: "Hôte", value: [status.hostname, status.user.isEmpty ? nil : "compte \(status.user)"]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), mono: true)
                        KeyValueRow(key: "Système", value: status.system.isEmpty ? "—" : status.system)
                        KeyValueRow(key: "Conteneurs", value: containersText(status))
                        KeyValueRow(key: "Sauvegarde", value: backupText(status))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow(key: "Relais annoncés", value: status.relayServers.isEmpty ? "—" : status.relayServers.joined(separator: ", "), mono: true)
                        KeyValueRow(key: "Bande passante", value: bandwidthText(status))
                        KeyValueRow(key: "Demandes gardées", value: status.punchSupported ? "\(status.punchTotal) depuis le démarrage de hbbs" : "—")
                        KeyValueRow(key: "Lecture", value: "SSH en lecture seule · consoles 127.0.0.1 par \(status.tcpClient.isEmpty ? "—" : status.tcpClient)")
                    }
                }
            }
        }
    }

    private func containersText(_ status: RustDeskServerStatus) -> String {
        if !status.containers.isEmpty {
            // Même image et même état : une seule mention (« hbbs, hbbr · image · en marche depuis 3 jours »).
            let images = Set(status.containers.map(\.image)), states = Set(status.containers.map(\.status))
            if images.count == 1, states.count == 1, let first = status.containers.first {
                return status.containers.map(\.name).joined(separator: ", ") + " · \(first.image) · "
                    + RustDeskServerFormat.dockerStatus(first.status)
            }
            return status.containers.map { "\($0.name) (\($0.image), \(RustDeskServerFormat.dockerStatus($0.status)))" }.joined(separator: " · ")
        }
        switch status.dockerSkipped {
        case "groupe-docker"?: return "Non lus\u{00A0}: le compte n’est pas dans le groupe docker (jamais de sudo)"
        case "docker-absent"?: return "Docker absent" + (status.packages.isEmpty ? "" : " · paquets " + status.packages.map { "\($0.name) \($0.version)" }.joined(separator: ", "))
        default: return "—"
        }
    }

    private func backupText(_ status: RustDeskServerStatus) -> String {
        guard let backup = status.backups.first else { return "Aucun fichier de sauvegarde trouvé dans /opt/rustdesk" }
        let name = (backup.path as NSString).lastPathComponent
        return "\(name) · \(RemoteFormat.relative(backup.date)) · \(RustDeskServerFormat.bytes(backup.bytes))"
    }

    private func bandwidthText(_ status: RustDeskServerStatus) -> String {
        guard status.totalBandwidth != nil || status.sessionBandwidth != nil else { return "—" }
        return "total \(RustDeskServerDashboard.mbps(status.totalBandwidth)) · par session \(RustDeskServerDashboard.mbps(status.sessionBandwidth))"
    }

    /// « 1024Mb/s » de hbbr → « 1024 Mbit/s ».
    static func mbps(_ raw: String?) -> String {
        guard let raw else { return "—" }
        return raw.replacingOccurrences(of: "Mb/s", with: "\u{00A0}Mbit/s").replacingOccurrences(of: ".", with: ",")
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Tuile du tableau de bord : intitulé, grande valeur, détail ; pastille et jauge facultatives.
struct RustDeskServerTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var tone: Tone? = nil
    /// Pastille d'état devant la valeur (processus).
    var dot = false
    /// Jauge (disque).
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.captionSemibold).kerning(0.4)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if dot { Circle().fill((tone ?? .neutral).dot).frame(width: 8, height: 8) }
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tone == .critical ? Theme.critical : tone == .warning ? Theme.warning : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let fraction {
                ProgressBar(fraction: fraction, color: fraction >= 0.9 ? Theme.warning : RemoteProtocol.rustdesk.tint, height: 4)
            }
            Text(detail)
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Graphe local des six dernières heures : sessions relayées et débit relayé, d'après les
/// échantillons pris par NetScope pendant que le tableau de bord était ouvert (trous : fermé).
struct RustDeskServerChart: View {
    let samples: [RustDeskServerSample]
    let now: Date

    /// Suites d'échantillons sans trou de plus de cinq minutes (une suite = une série du graphe).
    private var runs: [(id: Int, samples: [RustDeskServerSample])] {
        var result: [(Int, [RustDeskServerSample])] = []
        var current: [RustDeskServerSample] = []
        for sample in samples {
            if let last = current.last, sample.date.timeIntervalSince(last.date) > 300 {
                result.append((result.count, current))
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append((result.count, current)) }
        return result
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Six dernières heures", subtitle: "mesuré par ce Mac") {
                    HStack(spacing: 12) {
                        legend("Sessions relayées", color: RemoteProtocol.rustdesk.tint)
                        legend("Débit relayé", color: Theme.warning, dashed: true)
                    }
                }
                if samples.count < 2 {
                    Text("Le graphe se remplit pendant que ce tableau de bord est ouvert (une mesure à chaque lecture, gardée trois jours sur ce Mac).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                } else {
                    let maxSessions = max(2, samples.map(\.sessions).max() ?? 0)
                    let maxMbps = max(1, Double(samples.map(\.kbps).max() ?? 0) / 1_000)
                    Chart {
                        ForEach(runs, id: \.id) { run in
                            ForEach(run.samples, id: \.date) { sample in
                                AreaMark(x: .value("Heure", sample.date), y: .value("Sessions", sample.sessions),
                                         series: .value("Suite", "s\(run.id)"))
                                    .interpolationMethod(.stepEnd)
                                    .foregroundStyle(RemoteProtocol.rustdesk.tint.opacity(0.18))
                                LineMark(x: .value("Heure", sample.date), y: .value("Sessions", sample.sessions),
                                         series: .value("Suite", "s\(run.id)"))
                                    .interpolationMethod(.stepEnd)
                                    .foregroundStyle(RemoteProtocol.rustdesk.tint)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                                LineMark(x: .value("Heure", sample.date),
                                         y: .value("Sessions", Double(sample.kbps) / 1_000 / maxMbps * Double(maxSessions)),
                                         series: .value("Suite", "d\(run.id)"))
                                    .foregroundStyle(Theme.warning)
                                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [4, 2]))
                            }
                        }
                    }
                    .chartXScale(domain: now.addingTimeInterval(-6 * 3_600)...now)
                    .chartYScale(domain: 0...Double(maxSessions))
                    .chartYAxis {
                        // Au plus cinq graduations entières, quel que soit le nombre de sessions.
                        AxisMarks(position: .leading, values: Array(stride(from: 0, through: maxSessions, by: max(1, Int((Double(maxSessions) / 4).rounded(.up))))).map(Double.init)) { value in
                            AxisGridLine().foregroundStyle(Theme.neutralSoft)
                            AxisValueLabel {
                                if let count = value.as(Double.self) {
                                    Text("\(Int(count))").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        AxisMarks(position: .trailing, values: [0, Double(maxSessions)]) { value in
                            AxisValueLabel {
                                if let scaled = value.as(Double.self) {
                                    Text(RustDeskServerFormat.kbps(Int(scaled / Double(maxSessions) * maxMbps * 1_000)))
                                        .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour)) { value in
                            AxisGridLine().foregroundStyle(Theme.neutralSoft)
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(RemoteFormat.time(date)).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
    }

    private func legend(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5))
                path.addLine(to: CGPoint(x: 12, y: 1.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: dashed ? 2 : 3, dash: dashed ? [4, 2] : []))
            .frame(width: 12, height: 3)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
