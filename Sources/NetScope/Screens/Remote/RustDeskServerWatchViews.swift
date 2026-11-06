import NetScopeCore
import SwiftUI

// Note 87 (0.33.0) : panneaux du tableau de bord du serveur RustDesk — mises à jour, clé publique
// et sauvegarde, tentatives suspectes, historique et rapport mensuel, journaux, alertes de
// Surveillance ; fiche « Nom et note » d'un ID et association d'un ID à une fiche d'inventaire.

// MARK: - Mises à jour

struct RustDeskUpdatesPanel: View {
    let status: RustDeskServerStatus
    @ObservedObject var watch: RustDeskServerWatchModel

    private var installed: String? {
        watch.detail?.hbbsVersion ?? status.version
    }

    private var localDigests: [String] {
        ((watch.detail?.images ?? []) + status.images).compactMap { $0.digest() }
    }

    var body: some View {
        let findings = RustDeskUpdateAssessment.findings(installed: installed, localDigests: localDigests, published: watch.contents.published,
                                                         updates: watch.detail?.updates, clientVersion: RustDeskServerWatchModel.clientVersion)
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Mises à jour à vérifier", subtitle: subtitle) {
                    Button {
                        watch.checkNow()
                    } label: {
                        if watch.detailReading || watch.checkingVersions {
                            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Vérification…") }
                        } else {
                            Label("Vérifier maintenant", systemImage: "arrow.triangle.2.circlepath").labelStyle(RemoteCompactLabelStyle())
                        }
                    }
                    .buttonStyle(RemoteSmallButtonStyle())
                    .disabled(watch.detailReading || watch.checkingVersions)
                    .help("Lit le serveur par SSH (sudo au Trousseau si nécessaire) et les dernières versions publiées (Docker Hub, GitHub). Rien n’est installé.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow(key: "RustDesk Server", value: serverText)
                        KeyValueRow(key: "Image", value: imageText, mono: true)
                        KeyValueRow(key: "Client de ce Mac", value: clientText)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow(key: "Système", value: systemText)
                        KeyValueRow(key: "Redémarrage", value: watch.detail?.updates.map { $0.rebootRequired ? "Requis" : "Non requis" } ?? "—")
                        KeyValueRow(key: "Lecture", value: readText)
                    }
                }
                ForEach(findings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        RustDeskLevelIcon(level: finding.level).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                if let error = watch.detailError ?? watch.contents.published.error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var subtitle: String {
        guard let checked = watch.contents.published.checkedAt else { return "versions publiées jamais lues" }
        return "versions publiées lues · \(RemoteFormat.relative(checked))"
    }

    private var serverText: String {
        let latest = watch.contents.published.server
        switch (installed, latest) {
        case let (installed?, latest?): return "\(installed) · dernière publiée \(latest)"
        case let (installed?, nil): return installed
        case let (nil, latest?): return "inconnue · dernière publiée \(latest)"
        default: return "—"
        }
    }

    private var imageText: String {
        let image = (watch.detail?.containers ?? status.containerDetails).first?.image ?? status.containers.first?.image ?? "—"
        guard let local = localDigests.first else { return image }
        var text = image + " · " + RustDeskUpdateAssessment.short(local)
        if let hub = watch.contents.published.hubDigest { text += local == hub ? " (= Docker Hub)" : " (Docker Hub\u{00A0}: \(RustDeskUpdateAssessment.short(hub)))" }
        return text
    }

    private var clientText: String {
        guard let version = RustDeskServerWatchModel.clientVersion else { return "RustDesk non installé" }
        guard let latest = watch.contents.published.client else { return version }
        return RustDeskVersionCheck.compare(version, latest) == .orderedAscending ? "\(version) · \(latest) disponible" : "\(version) · à jour"
    }

    private var systemText: String {
        guard let updates = watch.detail?.updates else { return watch.detail == nil ? "Non lu" : "Gestionnaire de paquets inconnu" }
        if updates.packages.isEmpty { return "À jour (\(updates.manager))" }
        return "\(updates.packages.count) mise\(updates.packages.count > 1 ? "s" : "") à jour, dont \(updates.security.count) de sécurité (\(updates.manager))"
    }

    private var readText: String {
        guard let detail = watch.detail else { return "Pas encore lue" }
        var parts = [RemoteFormat.relative(detail.readAt)]
        switch detail.sudo {
        case "ok": parts.append("sudo accepté")
        case "root": parts.append("compte root")
        case "refuse": parts.append("sudo refusé")
        default: break
        }
        if let lists = detail.updates?.listsDate { parts.append("listes de paquets du \(RustDeskRequestRow.moment(lists))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Clé publique et sauvegarde

struct RustDeskKeyBackupPanel: View {
    let status: RustDeskServerStatus
    @ObservedObject var watch: RustDeskServerWatchModel
    @ObservedObject var server: RustDeskServerModel

    private var key: String? {
        status.publicKey.value ?? watch.detail?.publicKey.value
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Clé publique et sauvegarde")
                if let key, let known = watch.contents.knownKey, key != known {
                    HStack(alignment: .top, spacing: 10) {
                        RustDeskLevelIcon(level: .error).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("La clé publique du serveur a changé").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            Text("Les postes configurés avec l’ancienne clé ne se connectent plus (et une clé changée sans raison peut signaler un serveur remplacé). Ancienne\u{00A0}: \(known)")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button("C’est voulu") { watch.acceptKey(key) }.buttonStyle(RemoteSmallButtonStyle())
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.criticalSoft))
                }
                HStack(spacing: 8) {
                    Text("Clé").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                    Text(key ?? keyMissing).font(key == nil ? Theme.small : Theme.mono(12)).foregroundStyle(key == nil ? Theme.textSecondary : Theme.text)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let key {
                        Button {
                            RustDeskModel.shared.copy(key)
                        } label: { Label("Copier", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle()) }
                            .buttonStyle(RemoteSmallButtonStyle())
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("Copie sur ce Mac").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                    Text(backupText).font(Theme.small)
                        .foregroundStyle(RustDeskServerAlerts.backupDue(last: watch.lastBackup, now: status.now) ? Theme.warning : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        watch.revealBackups()
                    } label: { Label("Afficher", systemImage: "folder").labelStyle(RemoteCompactLabelStyle()) }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .disabled(watch.lastBackup == nil)
                    Button {
                        watch.backup()
                    } label: {
                        if watch.backupRunning {
                            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Copie…") }
                        } else {
                            Label("Sauvegarder la clé et la base", systemImage: "externaldrive.badge.checkmark").labelStyle(RemoteCompactLabelStyle())
                        }
                    }
                    .buttonStyle(RemoteSmallButtonStyle(primary: RustDeskServerAlerts.backupDue(last: watch.lastBackup, now: status.now)))
                    .disabled(watch.backupRunning || !server.settings.hasAccount)
                    .help("Lit le dossier de données du serveur (clés et db_v2.sqlite3) par sudo et l’enregistre chiffré sur ce Mac (clé au Trousseau). Rien n’est écrit sur le serveur.")
                }
                if let message = watch.backupMessage {
                    Text(message.text).font(Theme.caption).foregroundStyle(message.ok ? Theme.success : Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keyMissing: String {
        status.publicKey == .unreadable ? "Fichier id_ed25519.pub illisible sans sudo («\u{00A0}Vérifier maintenant\u{00A0}» la lit avec sudo)" : "Non lue"
    }

    private var backupText: String {
        guard let last = watch.lastBackup else { return "Aucune copie\u{00A0}: la clé privée et la base des postes ne sont sauvegardées nulle part par NetScope." }
        let due = RustDeskServerAlerts.backupDue(last: last, now: status.now)
        return "Dernière copie chiffrée \(RemoteFormat.relative(last))" + (due ? " · plus de 7 jours, à refaire" : "")
    }
}

// MARK: - Tentatives suspectes

struct RustDeskSuspiciousPanel: View {
    let events: [RustDeskSuspiciousEvent]
    @ObservedObject var watch: RustDeskServerWatchModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Tentatives suspectes", subtitle: events.isEmpty ? "7 derniers jours" : "\(events.count) · 7 derniers jours") { EmptyView() }
                if events.isEmpty {
                    Text("Aucune\u{00A0}: pas d’ID hors carnet, pas de rafale, aucun refus de la FortiGate vers les ports RustDesk.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(events.prefix(8)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(event.kind)).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(event.kind == .unknownID ? Theme.textSecondary : Theme.warning)
                                .frame(width: 14)
                            Text(event.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(detail(event)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(RustDeskRequestRow.moment(event.last)).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func icon(_ kind: RustDeskSuspiciousEvent.Kind) -> String {
        switch kind {
        case .unknownID: return "questionmark.circle"
        case .burst: return "bolt.fill"
        case .firewallDenied: return "shield.lefthalf.filled"
        }
    }

    private func detail(_ event: RustDeskSuspiciousEvent) -> String {
        guard event.kind != .unknownID, let site = watch.probableSite(event.key) else { return event.detail }
        return event.detail + " · site probable\u{00A0}: \(site)"
    }
}

// MARK: - Historique et rapport mensuel

struct RustDeskHistoryPanel: View {
    @ObservedObject var watch: RustDeskServerWatchModel
    @State private var chosen: Int?

    var body: some View {
        let months = RustDeskMonthlyReport.months(watch.contents.history)
        let current = months.first { $0.year * 100 + $0.month == chosen } ?? months.first
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Historique des demandes", subtitle: subtitle) {
                    if let current {
                        HStack(spacing: 6) {
                            Menu(RustDeskServerWatchViews.monthTitle(current.year, current.month)) {
                                ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                                    Button(RustDeskServerWatchViews.monthTitle(month.year, month.month)) { chosen = month.year * 100 + month.month }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                            Button("CSV") { watch.exportCSV(watch.report(year: current.year, month: current.month)) }
                                .buttonStyle(RemoteSmallButtonStyle())
                            Button("PDF") { watch.exportPDF(watch.report(year: current.year, month: current.month)) }
                                .buttonStyle(RemoteSmallButtonStyle())
                        }
                    }
                }
                if let current {
                    let report = watch.report(year: current.year, month: current.month)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PAR POSTE").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                            ForEach(report.stations.prefix(5)) { row in
                                line(row.name.isEmpty ? RustDeskID.grouped(row.targetID) : row.name, "\(row.count) · \(row.technicians) tech.")
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PAR TECHNICIEN").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                            ForEach(report.technicians.prefix(5)) { row in
                                line(row.label == row.ip ? row.ip : "\(row.label) · \(row.ip)", "\(row.count) · \(row.stations) poste\(row.stations > 1 ? "s" : "")")
                            }
                        }
                    }
                } else {
                    Text("L’historique se remplit à chaque lecture du serveur\u{00A0}: hbbs perd sa liste à chaque redémarrage, NetScope la garde jour après jour (400 jours).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var subtitle: String {
        let history = watch.contents.history
        guard let first = history.first?.date else { return "vide" }
        let days = Set(history.map { Calendar.current.startOfDay(for: $0.date) }).count
        return "\(history.count) demandes gardées sur \(days) jours, depuis le \(RustDeskRequestRow.moment(first))"
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Journaux

struct RustDeskLogsPanel: View {
    @ObservedObject var watch: RustDeskServerWatchModel

    var body: some View {
        let lines = watch.filteredLogs
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Journaux de hbbs et hbbr", subtitle: watch.logs.isEmpty ? "lus à la demande" : "\(lines.count) sur \(watch.logs.count) lignes") {
                    Button {
                        watch.readLogs()
                    } label: {
                        if watch.logsReading {
                            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Lecture…") }
                        } else {
                            Label(watch.logs.isEmpty ? "Lire les journaux" : "Relire", systemImage: "text.alignleft").labelStyle(RemoteCompactLabelStyle())
                        }
                    }
                    .buttonStyle(RemoteSmallButtonStyle())
                    .disabled(watch.logsReading)
                }
                if !watch.logs.isEmpty {
                    HStack(spacing: 8) {
                        SearchField(text: $watch.logSearch, placeholder: "Rechercher dans les journaux")
                        SearchField(text: $watch.logID, placeholder: "ID RustDesk").frame(width: 170)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(lines.suffix(300).reversed()) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.date.map { RustDeskRequestRow.moment($0) } ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                                        .frame(width: 92, alignment: .leading)
                                    Text(line.service).font(Theme.mono(11, weight: .semibold)).foregroundStyle(RemoteProtocol.rustdesk.tint)
                                        .frame(width: 36, alignment: .leading)
                                    Text(line.text).font(Theme.mono(11))
                                        .foregroundStyle(line.level == "ERROR" ? Theme.critical : line.level == "WARN" ? Theme.warning : Theme.text)
                                        .lineLimit(2).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(220, CGFloat(max(lines.count, 1)) * 16 + 6))
                }
                if let error = watch.logsError {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Alertes de Surveillance

struct RustDeskAlertsPanel: View {
    @ObservedObject var watch: RustDeskServerWatchModel
    @State private var portsText: String?
    @State private var message: String?

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Alertes de Surveillance")
                Text("L’agent de NetScope (application fermée) lit le serveur toutes les 5\u{00A0}minutes et alerte si hbbs ou hbbr s’arrête, si le disque dépasse 90\u{00A0}% ou si la clé publique change\u{00A0}; une sonde TCP par port surveillé, lancée depuis ce Mac (réseau local ou VPN), signale un port injoignable\u{00A0}; elle ne prouve pas que le port est joignable d’Internet (NAT, filtre géographique). 21118 et 21119 (WebSocket) sont souvent fermés\u{00A0}: retirez-les pour éviter de fausses alertes.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Ports surveillés").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    TextField("21115, 21116, 21117", text: Binding(
                        get: { portsText ?? watch.contents.monitoredPorts.map(String.init).joined(separator: ", ") },
                        set: { portsText = $0 }))
                        .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 220)
                        .onSubmit {
                            if let portsText { watch.setMonitoredPorts(portsText) }
                            portsText = nil
                        }
                    Button {
                        if let portsText { watch.setMonitoredPorts(portsText) }
                        portsText = nil
                        let added = watch.addProbes()
                        message = added == 0 ? "Sondes déjà présentes dans Surveillance." : "\(added) sonde\(added > 1 ? "s" : "") ajoutée\(added > 1 ? "s" : "") à Surveillance."
                    } label: { Label("Ajouter à Surveillance", systemImage: "waveform.path.ecg").labelStyle(RemoteCompactLabelStyle()) }
                        .buttonStyle(RemoteSmallButtonStyle())
                    if let message { Text(message).font(Theme.caption).foregroundStyle(Theme.success) }
                }
            }
        }
    }
}

// MARK: - Fiche « Nom et note »

struct RustDeskNoteSheet: View {
    let target: RustDeskNoteTarget
    @ObservedObject var watch: RustDeskServerWatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.kind == .id ? "Nom et note · ID \(RustDeskID.grouped(target.key))" : "Nom du technicien · \(target.key)")
                .font(Theme.panelTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nom").font(Theme.small).foregroundStyle(Theme.textSecondary)
                TextField(target.kind == .id ? "Poste de la réception" : "Marc (domicile)", text: $name).textFieldStyle(.roundedBorder)
            }
            if target.kind == .id {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $note).font(Theme.body).frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                }
                Text("Gardés dans NetScope et synchronisés entre vos Mac\u{00A0}; affichés dans le tableau de bord, l’assistance et le carnet.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if target.kind == .id { watch.setNote(target.key, name: name, note: note) } else { watch.setTechnician(target.key, name: name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if target.kind == .id {
                name = watch.note(for: target.key)?.name ?? ""
                note = watch.note(for: target.key)?.note ?? ""
            } else {
                name = watch.technicianName(target.key) ?? ""
            }
        }
    }
}

// MARK: - Association à une fiche

struct RustDeskAssociationSheet: View {
    let request: RustDeskAssociationRequest
    @ObservedObject var watch: RustDeskServerWatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Associer l’ID \(RustDeskID.grouped(request.id)) à une fiche").font(Theme.panelTitle)
            Text(explanation).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if request.searching {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Recherche…").font(Theme.small) }
            } else if request.candidates.isEmpty {
                Text("Aucun poste proposé\u{00A0}: IP privée absente du dernier scan, site inconnu (WAN des FortiGate non lu), ou aucune session vers le serveur dans la table de la FortiGate de ce site.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(request.candidates) { candidate in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name).font(Theme.bodySemibold)
                            Text("\(candidate.ip)\(candidate.mac.map { " · \($0)" } ?? "") · \(candidate.reason)")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if let site = candidate.site, site != watch.activeSiteName {
                            Text("Ouvrir le site «\u{00A0}\(site)\u{00A0}» pour associer")
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.trailing)
                        } else if !candidate.canAssociate(activeSite: watch.activeSiteName) {
                            Text("Indice seulement (MAC inconnue)")
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.trailing)
                                .help("Sans MAC, la fiche ne peut pas être retrouvée sûrement\u{00A0}: l’IP seule ne choisit jamais un appareil. Lancez un scan du site, puis réessayez.")
                        } else {
                            Button("Associer") {
                                if watch.associate(candidate, id: request.id) { dismiss() } else {
                                    failed = "Aucune fiche avec cette MAC dans le site actif\u{00A0}: ouvrez le bon site, ou lancez un scan."
                                }
                            }
                            .buttonStyle(RemoteSmallButtonStyle(primary: candidate.relay))
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                }
            }
            if let failed { Text(failed).font(Theme.caption).foregroundStyle(Theme.critical) }
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private var explanation: String {
        if RustDeskSiteHint.isPrivate(request.targetIP) {
            let site = watch.activeSiteName.map { " du site «\u{00A0}\($0)\u{00A0}»" } ?? ""
            return "hbbs voit le poste à \(request.targetIP), une adresse privée\u{00A0}: NetScope propose l’appareil qui a cette IP au dernier scan\(site) (un autre site peut avoir la même IP). Vérifiez avant d’associer\u{00A0}: l’ID sera retenu par la MAC de la fiche."
        }
        let site = watch.probableSite(request.targetIP).map { "site probable\u{00A0}: \($0)" } ?? "site inconnu"
        return "hbbs voit le poste derrière \(request.targetIP) (NAT, \(site)). Les postes proposés parlent au serveur (21116, 21117) dans la table des sessions de la FortiGate de ce site\u{00A0}; l’IP seule ne tranche jamais, c’est vous qui confirmez."
    }
}

enum RustDeskServerWatchViews {
    static func monthTitle(_ year: Int, _ month: Int) -> String {
        RustDeskMonthlyReport.title(year: year, month: month).capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
