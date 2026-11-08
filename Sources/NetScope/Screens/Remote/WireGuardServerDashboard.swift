import Charts
import CoreImage.CIFilterBuiltins
import NetScopeCore
import SwiftUI

/// Note 100 (1.3.0) : onglet « Serveur WireGuard » d'Accès distant (wg-easy). Tuiles, graphe local,
/// clients (gestion par l'API de wg-easy 15, avec confirmation), mise à jour de l'image, journaux.
struct WireGuardServerDashboard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var wg = WireGuardServerModel.shared
    @ObservedObject private var server = RustDeskServerModel.shared
    @State private var width: CGFloat = 900

    private static let tint = Color(nsColor: .systemTeal)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !server.settings.hasAccount {
                    EmptyState(systemImage: "lock.shield", title: "Compte SSH du serveur à choisir",
                               message: "Le serveur WireGuard se lit avec le compte SSH du serveur RustDesk (même serveur, même sudo). Choisissez-le dans Réglages › RustDesk.") {
                        Button("Ouvrir Réglages › RustDesk") {
                            RegNavigation.shared.section = .rustdesk
                            state.open(.reglages)
                        }
                        .buttonStyle(.secondary)
                    }
                    .frame(height: 240)
                } else {
                    if let error = wg.error { banner(.critical, "exclamationmark.triangle.fill", error.title, error.detail + " " + error.advice) }
                    apiBanner
                    if let status = wg.status {
                        content(status).opacity(wg.error == nil ? 1 : 0.55)
                    } else if wg.error == nil {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            if wg.status == nil, wg.error == nil, server.settings.hasAccount { wg.refresh() }
        }
        .sheet(item: RegEnvironment.isSnapshot ? .constant(nil) : $wg.pending) { action in
            WireGuardConfirmSheet(action: action).interactiveDismissDisabled()
        }
        .sheet(item: RegEnvironment.isSnapshot ? .constant(nil) : $wg.shownConfig) { config in
            WireGuardConfigSheet(config: config)
        }
        .sheet(isPresented: $wg.showSettings) { WireGuardSettingsSheet() }
        .sheet(isPresented: $wg.addingClient) { WireGuardAddSheet() }
        .overlay(alignment: .top) {
            // Captures : une vraie feuille ne se capture pas hors écran ; elle est dessinée par-dessus.
            if RegEnvironment.isSnapshot, let action = wg.pending {
                ZStack(alignment: .top) {
                    Color(nsColor: .shadowColor).opacity(0.18)
                    WireGuardConfirmSheet(action: action)
                        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                        .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                        .padding(.top, 8)
                }
            } else if RegEnvironment.isSnapshot, let config = wg.shownConfig {
                ZStack(alignment: .top) {
                    Color(nsColor: .shadowColor).opacity(0.18)
                    WireGuardConfigSheet(config: config)
                        .fixedSize()
                        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                        .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                        .padding(.top, 8)
                }
            }
        }
    }

    // MARK: En-tête

    /// Petite fenêtre : les boutons passent sous le titre (le titre garde toute la largeur).
    @ViewBuilder private var header: some View {
        if width < 820 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) { headerIcon; headerTitle; Spacer(minLength: 0) }
                HStack(spacing: 8) { actions.fixedSize(); Spacer(minLength: 0); readTime }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                headerIcon
                headerTitle
                Spacer(minLength: 8)
                HStack(spacing: 8) { readTime; actions }.fixedSize()
            }
        }
    }

    private var headerIcon: some View {
        Image(systemName: "lock.shield")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Self.tint)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(Self.tint.opacity(0.14)))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Serveur WireGuard").font(Theme.panelTitle)
            Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        var parts = [wg.accountLabel ?? "Lecture par SSH"]
        if let container = wg.status?.container {
            let version = container.version.isEmpty ? (wg.status?.edition == .v14 ? "14" : "") : container.version
            parts.append("wg-easy\u{00A0}" + (version.isEmpty ? "(version inconnue)" : version))
        }
        parts.append(wg.canManage ? "gestion par l’API" : "lecture seule")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var readTime: some View {
        if let copied = wg.copied {
            Label(copied, systemImage: "checkmark").font(Theme.caption).foregroundStyle(Theme.success)
        } else if let status = wg.status {
            Text("Lu à \(RustDeskServerDashboard.clock(status.readAt))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { wg.showSettings = true } label: {
                Label("Réglages", systemImage: "gearshape").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .help("Adresse et compte de wg-easy, conteneur, clients surveillés")
            Button { wg.openWebInterface() } label: {
                Label("Interface web", systemImage: "safari").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .disabled(wg.webURL == nil)
            .help(wg.webURL.map { "Ouvre \($0.absoluteString) dans le navigateur" } ?? "Compte SSH du serveur à choisir d’abord")
            Button { wg.copyCommand() } label: {
                Label("Copier la commande", systemImage: "doc.on.doc").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .disabled(wg.accountLabel == nil)
            .help("Copie la commande ssh de lecture, à coller dans Terminal (aucun secret)")
            Button { wg.refresh() } label: {
                if wg.reading {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Lecture…") }
                } else {
                    Label("Actualiser", systemImage: "arrow.clockwise").labelStyle(RemoteCompactLabelStyle())
                }
            }
            .buttonStyle(RemoteSmallButtonStyle(primary: true))
            .disabled(wg.reading || !server.settings.hasAccount)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: Bandeaux

    private func banner(_ tone: Tone, _ symbol: String, _ title: String, _ detail: String) -> some View {
        banner(tone, symbol, title, detail) { EmptyView() }
    }

    private func banner<Actions: View>(_ tone: Tone, _ symbol: String, _ title: String, _ detail: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                actions().padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }

    @ViewBuilder private var apiBanner: some View {
        if let error = wg.apiError {
            banner(.warning, error.kind == .twoFactor ? "lock.fill" : "exclamationmark.triangle", "Gestion désactivée\u{00A0}: " + error.title, error.advice) { managementActions }
        } else if wg.apiBase == nil, wg.status != nil {
            banner(.warning, "lock.slash", "Gestion désactivée\u{00A0}: API de wg-easy non branchée",
                   "Entrez l’adresse et le mot de passe de l’API dans Réglages pour voir le nom des clients et pouvoir en ajouter, désactiver ou supprimer. En attendant, l’onglet lit le serveur par SSH.") { managementActions }
        }
        if wg.apiInsecure, wg.apiBase != nil {
            banner(.warning, "lock.open", "API en HTTP simple\u{00A0}: mot de passe en clair sur le réseau local",
                   "Chaque appel envoie le mot de passe administrateur sans chiffrement. HTTPS conseillé\u{00A0}; ne jamais exposer l’interface de wg-easy par une VIP de la FortiGate.")
        }
    }

    private var managementActions: some View {
        HStack(spacing: 6) {
            Button { wg.showSettings = true } label: {
                Label("Réglages", systemImage: "gearshape").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle(primary: true))
            Button { wg.openWebInterface() } label: {
                Label("Ouvrir l’interface web", systemImage: "safari").labelStyle(RemoteCompactLabelStyle())
            }
            .buttonStyle(RemoteSmallButtonStyle())
            .disabled(wg.webURL == nil)
            .help(wg.webURL?.absoluteString ?? "Compte SSH du serveur à choisir d’abord")
        }
    }

    // MARK: Contenu

    @ViewBuilder private func content(_ status: WireGuardServerStatus) -> some View {
        let now = status.readAt
        let rows = wg.rows
        ForEach(wg.findings(now: now).filter { $0.id != "http" }) { finding in
            HStack(alignment: .top, spacing: 0) {
                banner(finding.level == .error ? .critical : finding.level == .warning ? .warning : .neutral,
                       finding.level == .info ? "info.circle" : "exclamationmark.triangle.fill", finding.title, finding.detail)
                if finding.id == "cle" {
                    Button("Accepter la nouvelle clé") { wg.acceptServerKey() }.buttonStyle(RemoteSmallButtonStyle()).padding(10)
                }
            }
        }
        tiles(status, rows: rows, now: now)
        WireGuardChart(samples: wg.settings.samples.filter { now.timeIntervalSince($0.date) <= 6 * 3_600 }, now: now, tint: Self.tint)
        Panel { clientsTable(rows, now: now) }
        if let result = wg.lastResult, wg.pending == nil { resultPanel(result) }
        updatePanel(status)
        historyPanel
        logsPanel(status)
        serverPanel(status)
        Text("«\u{00A0}Connecté\u{00A0}»\u{00A0}: poignée de main il y a moins de 3 minutes. Débits mesurés par ce Mac entre deux lectures (tous les clients). L’IP d’origine n’est qu’un indice\u{00A0}: elle ne désigne jamais à elle seule un site ou un appareil. NetScope ne lit ni ne garde aucune clé privée\u{00A0}; le fichier .conf montré est oublié à la fermeture.")
            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tiles(_ status: WireGuardServerStatus, rows: [WireGuardClientRow], now: Date) -> some View {
        let connected = rows.filter { $0.isConnected(now: now) }.count
        let enabled = rows.filter(\.enabled).count
        let samples = wg.settings.samples
        let rate = samples.count >= 2 ? WireGuardSamples.rate(from: samples[samples.count - 2], to: samples[samples.count - 1]) : nil
        let received = rows.reduce(Int64(0)) { $0 + $1.receivedBytes }, sent = rows.reduce(Int64(0)) { $0 + $1.sentBytes }
        let expiring = rows.filter { row in row.enabled && row.expiresAt.map { $0 > now && $0.timeIntervalSince(now) < Double(wg.settings.watch.expiryDays) * 86_400 } ?? false }.count
        let container = status.container
        let columns = width < 700 ? 2 : 4
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), alignment: .leading, spacing: 10) {
            RustDeskServerTile(title: "Clients connectés", value: "\(connected) / \(enabled)", detail: "\(rows.count) client\(rows.count > 1 ? "s" : "") au total")
            RustDeskServerTile(title: "Débit ↓ ↑", value: rate.map { WireGuardSamples.bitrate($0.down + $0.up) } ?? "—",
                               detail: rate.map { "↓ \(WireGuardSamples.bitrate($0.down)) · ↑ \(WireGuardSamples.bitrate($0.up))" } ?? "entre deux lectures")
            RustDeskServerTile(title: "Totaux", value: RustDeskServerFormat.bytes(received + sent),
                               detail: "↓ \(RustDeskServerFormat.bytes(received)) · ↑ \(RustDeskServerFormat.bytes(sent))")
            RustDeskServerTile(title: "Expirent bientôt", value: "\(expiring)", detail: "dans moins de \(wg.settings.watch.expiryDays)\u{00A0}j",
                               tone: expiring > 0 ? .warning : nil)
            RustDeskServerTile(title: "Conteneur", value: container?.isRunning == true ? "En marche" : "Arrêté",
                               detail: container.map { c in c.startedAt.map { "depuis \(RustDeskServerFormat.duration(Int(now.timeIntervalSince($0))))" } ?? c.state } ?? "introuvable",
                               tone: container?.isRunning == true ? .success : .critical, dot: true)
            RustDeskServerTile(title: "Version", value: versionValue(status), detail: versionDetail(status),
                               tone: wg.apiInfo?.updateAvailable == true ? .warning : nil)
            RustDeskServerTile(title: "Port UDP", value: status.listenPort.map(String.init) ?? "—", detail: "interface wg0")
            RustDeskServerTile(title: "Redémarrages", value: container.map { "\($0.restarts)" } ?? "—", detail: "du conteneur",
                               tone: (container?.restarts ?? 0) > 0 ? .warning : nil)
        }
    }

    private func versionValue(_ status: WireGuardServerStatus) -> String {
        if let current = wg.apiInfo?.currentRelease { return current }
        if let version = status.container?.version, !version.isEmpty { return version }
        return status.edition == .v14 ? "14" : status.edition == .v15 ? "15" : "—"
    }

    private func versionDetail(_ status: WireGuardServerStatus) -> String {
        if let info = wg.apiInfo, let latest = info.latestRelease {
            return info.updateAvailable ? "\(latest) publiée" : "à jour"
        }
        return status.container?.image ?? "image inconnue"
    }

    // MARK: Clients

    @ViewBuilder private func clientsTable(_ rows: [WireGuardClientRow], now: Date) -> some View {
        let wide = width >= 860
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Clients", subtitle: wg.canManage ? "gestion par l’API de wg-easy" : "lecture seule, gestion désactivée") {
                HStack(spacing: 6) {
                    if wg.canManage, !wg.selectedIDs.isEmpty {
                        Text("\(wg.selectedIDs.count) choisi\(wg.selectedIDs.count > 1 ? "s" : "")").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        Button("Activer") { wg.askBatch(enable: true) }.buttonStyle(RemoteSmallButtonStyle())
                        Button("Désactiver") { wg.askBatch(enable: false) }.buttonStyle(RemoteSmallButtonStyle())
                        Button("Supprimer") { wg.askDelete(wg.selectedIDs) }.buttonStyle(RemoteSmallButtonStyle())
                    }
                    if let undo = wg.lastUndoable, wg.canManage {
                        Button { wg.undoLast() } label: {
                            Label("Annuler la dernière modification", systemImage: "arrow.uturn.backward").labelStyle(RemoteCompactLabelStyle())
                        }
                        .buttonStyle(RemoteSmallButtonStyle())
                        .help("Retour arrière\u{00A0}: " + undo.summary)
                    }
                    Button { wg.addingClient = true } label: {
                        Label("Ajouter un client", systemImage: "plus").labelStyle(RemoteCompactLabelStyle())
                    }
                    .buttonStyle(RemoteSmallButtonStyle(primary: true))
                    .disabled(!wg.canManage)
                    .help(wg.canManage ? "Nouveau client wg-easy (nom, expiration)" : "Gestion désactivée\u{00A0}: entrez l’adresse et le mot de passe de l’API dans Réglages")
                }
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 16)
                header("NOM").frame(maxWidth: .infinity, alignment: .leading)
                header("ADRESSE").frame(width: 92, alignment: .leading)
                header("ÉTAT").frame(width: 128, alignment: .leading)
                if wide { header("IP D’ORIGINE").frame(width: 120, alignment: .leading) }
                if width >= 760 { header("↓ / ↑").frame(width: 118, alignment: .trailing) }
                header("EXPIRATION").frame(width: 92, alignment: .leading)
                Color.clear.frame(width: 22)
            }
            Divider()
            if rows.isEmpty {
                Text("Aucun client.").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.vertical, 8)
            }
            ForEach(rows) { row in
                clientRow(row, now: now, wide: wide)
                Divider().opacity(0.5)
            }
            if rows.contains(where: { $0.unnamedKey != nil }) {
                Text("WireGuard ne connaît que les clés\u{00A0}: les noms viennent de l’API de wg-easy (Réglages) ou de la base (sqlite3 sur le serveur).")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }

    private func clientRow(_ row: WireGuardClientRow, now: Date, wide: Bool) -> some View {
        let connected = row.isConnected(now: now)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { wg.selection.contains(row.id) }, set: { on in
                if on { wg.selection.insert(row.id) } else { wg.selection.remove(row.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().frame(width: 16)
            .disabled(row.apiID == nil || !wg.canManage)
            HStack(spacing: 5) {
                if wg.isImportant(row) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.warning).help("Client surveillé")
                }
                if let key = row.unnamedKey {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Client sans nom").font(Theme.bodySemibold).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Text(key).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    .help("Clé publique\u{00A0}: " + row.publicKey)
                } else {
                    Text(row.name).font(Theme.bodySemibold).foregroundStyle(row.enabled ? Theme.text : Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.ipv4.isEmpty ? "—" : row.ipv4).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 5) {
                StatusDot(tone: !row.enabled || !connected ? .neutral : .success)
                Text(stateText(row, now: now, connected: connected)).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)
            if wide {
                Text(row.endpointAddress ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                    .help("IP d’origine vue par le serveur (indice seulement)")
            }
            if width >= 760 {
                Text(row.receivedBytes + row.sentBytes == 0 ? "—" : "\(RustDeskServerFormat.bytes(row.receivedBytes)) / \(RustDeskServerFormat.bytes(row.sentBytes))")
                    .font(Theme.small).monospacedDigit().foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .frame(width: 118, alignment: .trailing)
            }
            Text(expiryText(row, now: now)).font(Theme.small).foregroundStyle(expiryTone(row, now: now)).lineLimit(1)
                .frame(width: 92, alignment: .leading)
            rowMenu(row).frame(width: 22)
        }
        .padding(.vertical, 3)
    }

    private func stateText(_ row: WireGuardClientRow, now: Date, connected: Bool) -> String {
        if !row.enabled { return "Désactivé" }
        if connected { return "Connecté" }
        guard let handshake = row.latestHandshake else { return "Jamais connecté" }
        return "il y a " + RustDeskServerFormat.duration(Int(now.timeIntervalSince(handshake)))
    }

    private func expiryText(_ row: WireGuardClientRow, now: Date) -> String {
        guard let date = row.expiresAt else { return "—" }
        if date < now { return "expiré" }
        let days = Int((date.timeIntervalSince(now) / 86_400).rounded(.down))
        return days == 0 ? "aujourd’hui" : "dans \(days)\u{00A0}j"
    }

    private func expiryTone(_ row: WireGuardClientRow, now: Date) -> Color {
        guard let date = row.expiresAt, row.enabled else { return Theme.textSecondary }
        return date.timeIntervalSince(now) < Double(wg.settings.watch.expiryDays) * 86_400 ? Theme.warning : Theme.textSecondary
    }

    private func rowMenu(_ row: WireGuardClientRow) -> some View {
        Menu {
            if let id = row.apiID, wg.canManage {
                Button("Fichier .conf et code QR…") { wg.showConfiguration(id) }
                Button("Copier un lien à usage unique") { wg.copyOneTimeLink(id) }
                Divider()
                Button(row.enabled ? "Désactiver…" : "Activer…") { wg.askToggle(id, name: row.name, enable: !row.enabled) }
                Menu("Expiration") {
                    Button("Dans 7 jours") { wg.askExpiry(id, name: row.name, date: Date().addingTimeInterval(7 * 86_400)) }
                    Button("Dans 30 jours") { wg.askExpiry(id, name: row.name, date: Date().addingTimeInterval(30 * 86_400)) }
                    Button("Dans 90 jours") { wg.askExpiry(id, name: row.name, date: Date().addingTimeInterval(90 * 86_400)) }
                    Button("Aucune") { wg.askExpiry(id, name: row.name, date: nil) }
                }
                Button("Renommer…") { renameTarget = row }
                Divider()
                Button("Supprimer…", role: .destructive) { wg.askDelete([id]) }
                Divider()
            }
            Button(wg.isImportant(row) ? "Ne plus surveiller" : "Surveiller ce client") { wg.toggleImportant(row) }
                .disabled(row.publicKey.isEmpty)
            Button("Copier la clé publique") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.publicKey, forType: .string)
            }
            .disabled(row.publicKey.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions sur le client")
        .popover(item: Binding(get: { renameTarget?.id == row.id ? renameTarget : nil }, set: { renameTarget = $0 })) { target in
            WireGuardRenamePopover(row: target) { renameTarget = nil }
        }
    }

    @State private var renameTarget: WireGuardClientRow?

    // MARK: Panneaux

    private func resultPanel(_ result: WireGuardChangeRecord) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(result.ok ? Theme.success : Theme.critical)
                    Text(result.summary).font(Theme.bodySemibold).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { wg.lastResult = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).help("Fermer")
                }
                ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: step.level == "ok" ? "checkmark" : step.level == "echec" ? "xmark" : "info.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(step.level == "ok" ? Theme.success : step.level == "echec" ? Theme.critical : Theme.textSecondary)
                        Text(step.text).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func updatePanel(_ status: WireGuardServerStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Mise à jour de wg-easy", subtitle: "image du conteneur, avec retour arrière") {
                    Button { wg.askUpdateImage() } label: {
                        if wg.running {
                            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Mise à jour…") }
                        } else {
                            Label("Mettre à jour l’image", systemImage: "arrow.down.circle").labelStyle(RemoteCompactLabelStyle())
                        }
                    }
                    .buttonStyle(RemoteSmallButtonStyle(primary: wg.apiInfo?.updateAvailable == true))
                    .disabled(wg.running || status.container == nil || status.edition == .v14)
                    .help(status.edition == .v14 ? "wg-easy 14\u{00A0}: migrer d’abord vers la 15 (guide officiel)" : "Sauvegarde, étiquette de l’image d’avant, pull, up -d, vérification")
                }
                KeyValueRow(key: "Image", value: status.container?.image ?? "—", mono: true)
                KeyValueRow(key: "Version", value: wg.apiInfo.map { info in
                    (info.currentRelease ?? "?") + (info.latestRelease.map { info.updateAvailable ? " · \($0) publiée" : " · à jour (\($0))" } ?? "")
                } ?? versionValue(status))
                KeyValueRow(key: "Système", value: "Mises à jour du système\u{00A0}: onglet «\u{00A0}Serveur RustDesk\u{00A0}» (même serveur)")
            }
        }
    }

    @ViewBuilder private var historyPanel: some View {
        if !wg.history.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Modifications", subtitle: "faites depuis ce Mac pendant cette session")
                    ForEach(wg.history.prefix(8)) { record in
                        HStack(alignment: .top, spacing: 8) {
                            Text(RustDeskServerDashboard.clock(record.date)).font(Theme.small).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                .frame(width: 44, alignment: .leading)
                            Image(systemName: record.ok ? "checkmark" : "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(record.ok ? Theme.success : Theme.critical)
                            Text(record.summary).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func logsPanel(_ status: WireGuardServerStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Journaux du conteneur", subtitle: "dernières lignes de docker logs")
                if status.logs.isEmpty {
                    Text("Aucune ligne lue.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(status.logs.suffix(12).joined(separator: "\n"))
                        .font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelMuted))
                }
            }
        }
    }

    private func serverPanel(_ status: WireGuardServerStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Serveur")
                KeyValueRow(key: "Clé publique", value: status.serverKey ?? "—", mono: true)
                KeyValueRow(key: "Édition", value: status.edition == .v15 ? "wg-easy 15 (base wg-easy.db)" : status.edition == .v14 ? "wg-easy 14 (wg0.json)" : "inconnue")
                KeyValueRow(key: "Base", value: status.databaseClients != nil ? "copiée puis lue en lecture seule (sqlite3)"
                            : status.sqliteMissing ? "non lue\u{00A0}: sqlite3 absent du serveur" : "non lue")
                KeyValueRow(key: "Adresse web", value: wg.webURL?.absoluteString ?? "—", mono: true)
                KeyValueRow(key: "Interface web", value: status.insecure == true ? "HTTP simple (INSECURE=true)" : status.insecure == false ? "HTTPS attendu" : "—")
                KeyValueRow(key: "Accès", value: status.access == "docker" ? "groupe docker" : status.access == "root" ? "root" : status.access == "ok" ? "sudo" : "sudo\u{00A0}: \(status.access)")
            }
        }
    }
}

// MARK: - Graphe

struct WireGuardChart: View {
    let samples: [WireGuardSample]
    let now: Date
    let tint: Color

    private var points: [(date: Date, connected: Int, mbps: Double)] {
        var result: [(Date, Int, Double)] = []
        for (a, b) in zip(samples, samples.dropFirst()) where b.date.timeIntervalSince(a.date) <= 600 {
            if let rate = WireGuardSamples.rate(from: a, to: b) { result.append((b.date, b.connected, (rate.down + rate.up) * 8 / 1_000_000)) }
        }
        return result
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Six dernières heures", subtitle: "mesuré par ce Mac") {
                    HStack(spacing: 12) {
                        legend("Clients connectés", color: tint)
                        legend("Débit (Mbit/s)", color: Theme.warning)
                    }
                }
                let data = points
                if data.count < 2 {
                    Text("Le graphe se remplit pendant que cet onglet est ouvert (une mesure à chaque lecture, gardée trois jours sur ce Mac).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                } else {
                    let maxClients = max(2, data.map(\.connected).max() ?? 0)
                    let maxMbps = max(1, data.map(\.mbps).max() ?? 1)
                    Chart {
                        ForEach(data, id: \.date) { point in
                            AreaMark(x: .value("Heure", point.date), y: .value("Clients", point.connected), series: .value("Série", "c"))
                                .interpolationMethod(.stepEnd).foregroundStyle(tint.opacity(0.18))
                            LineMark(x: .value("Heure", point.date), y: .value("Clients", point.connected), series: .value("Série", "c"))
                                .interpolationMethod(.stepEnd).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.5))
                            LineMark(x: .value("Heure", point.date), y: .value("Clients", point.mbps / maxMbps * Double(maxClients)), series: .value("Série", "d"))
                                .foregroundStyle(Theme.warning).lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [4, 2]))
                        }
                    }
                    .chartXScale(domain: now.addingTimeInterval(-6 * 3_600)...now)
                    .chartYScale(domain: 0...Double(maxClients))
                    .frame(height: 110)
                }
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Feuilles

/// Confirmation d'une modification : ce qui va se passer ; rien n'est envoyé avant le bouton.
struct WireGuardConfirmSheet: View {
    let action: WireGuardPendingAction
    @ObservedObject private var wg = WireGuardServerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action.title).font(Theme.panelTitle)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(action.consequences, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Theme.textSecondary)
                        Text(line).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if case .api = action.kind {
                Text(wg.apiInsecure ? "Envoyé par l’API de wg-easy en HTTP simple (mot de passe en clair sur le réseau local)." : "Envoyé par l’API de wg-easy.")
                    .font(Theme.caption).foregroundStyle(wg.apiInsecure ? Theme.warning : Theme.textSecondary)
            } else {
                Text("Par SSH, avec le compte et le sudo du serveur RustDesk.").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Annuler") { wg.dismiss() }.keyboardShortcut(.cancelAction).disabled(wg.running)
                Button(action.confirmLabel, role: action.destructive ? .destructive : nil) { wg.confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(wg.running)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct WireGuardRenamePopover: View {
    let row: WireGuardClientRow
    let done: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nouveau nom").font(Theme.bodySemibold)
            TextField("Nom du client", text: $name).frame(width: 240).onSubmit(submit)
            HStack {
                Spacer()
                Button("Annuler", action: done)
                Button("Renommer…", action: submit).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .onAppear { name = row.name }
    }

    private func submit() {
        if let id = row.apiID { WireGuardServerModel.shared.askRename(id, from: row.name, to: name) }
        done()
    }
}

struct WireGuardAddSheet: View {
    @ObservedObject private var wg = WireGuardServerModel.shared
    @State private var name = ""
    @State private var expires = false
    @State private var date = Date().addingTimeInterval(30 * 86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajouter un client").font(Theme.panelTitle)
            TextField("Nom (ex.\u{00A0}: Portable de Julie)", text: $name)
            Toggle("Date d’expiration", isOn: $expires)
            if expires {
                DatePicker("Expire le", selection: $date, in: Date()..., displayedComponents: .date)
            }
            Text("wg-easy choisit la prochaine adresse libre et crée les clés. Le .conf et le code QR se montrent ensuite, sans être gardés.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler") { wg.addingClient = false }.keyboardShortcut(.cancelAction)
                Button("Continuer…") {
                    wg.addingClient = false
                    let chosen = expires ? date : nil
                    let text = name
                    DispatchQueue.main.async { wg.askCreate(name: text, expiresAt: chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Fichier .conf et code QR, dessiné sur ce Mac ; tout est oublié à la fermeture.
struct WireGuardConfigSheet: View {
    let config: WireGuardShownConfig
    @ObservedObject private var wg = WireGuardServerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration de «\u{00A0}\(config.name)\u{00A0}»").font(Theme.panelTitle)
            HStack(alignment: .top, spacing: 16) {
                if let image = Self.qr(config.text) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .background(Color.white)
                        .help("Code QR à lire avec l’application WireGuard")
                }
                ScrollView {
                    Text(config.text).font(Theme.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 320, height: 220)
            }
            Text("Contient la clé privée du client\u{00A0}: à remettre seulement à son usager. NetScope ne la garde pas\u{00A0}; une copie est marquée confidentielle (ni historique ni presse-papiers universel) et s’efface d’elle-même après 60\u{00A0}s.")
                .font(Theme.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                .frame(width: 556, alignment: .leading)
            HStack {
                Button("Copier") { SecretPasteboard.copy(config.text) }
                Spacer()
                Button("Fermer") { wg.shownConfig = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Copie d'un secret : types « concealed » et « transient » (gestionnaires d'historique, presse-papiers
/// universel), puis effacement après 60 s si le presse-papiers n'a pas changé entre-temps.
enum SecretPasteboard {
    static let lifetime: TimeInterval = 60

    @MainActor static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        let stamp = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            if NSPasteboard.general.changeCount == stamp { NSPasteboard.general.clearContents() }
        }
    }
}

/// Réglages de l'onglet : adresse et compte de wg-easy (mot de passe au Trousseau), conteneur, surveillance.
struct WireGuardSettingsSheet: View {
    @ObservedObject private var wg = WireGuardServerModel.shared
    @State private var url = ""
    @State private var user = ""
    @State private var container = ""
    @State private var password = ""
    @State private var hours = 4.0
    @State private var days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Serveur WireGuard").font(Theme.panelTitle)
            Text("Compte SSH et sudo\u{00A0}: ceux du serveur RustDesk (Réglages › RustDesk).").font(Theme.small).foregroundStyle(Theme.textSecondary)
            Form {
                TextField("Adresse de wg-easy", text: $url, prompt: Text("http://serveur:51821"))
                TextField("Compte administrateur", text: $user)
                SecureField(wg.hasAPIPassword ? "Mot de passe (enregistré)" : "Mot de passe", text: $password, prompt: Text(wg.hasAPIPassword ? "••••••••" : ""))
                TextField("Conteneur", text: $container)
                Stepper("Client surveillé déconnecté depuis \(Int(hours))\u{00A0}h", value: $hours, in: 1...72)
                Stepper("Expiration proche\u{00A0}: \(days)\u{00A0}j", value: $days, in: 1...60)
            }
            if (try? WGEasyAPI.baseURL(url)).map(WGEasyAPI.plainHTTPBlocked) == true {
                Text(WGEasyAPI.plainHTTPAdvice)
                    .font(Theme.caption).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            } else if (try? WGEasyAPI.baseURL(url)).map(WGEasyAPI.isInsecure) == true {
                Text("HTTP simple\u{00A0}: le mot de passe circule en clair sur le réseau local. HTTPS conseillé.")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
            }
            Text("wg-easy 15 sans 2FA\u{00A0}: avec le 2FA, l’API refuse l’authentification Basic et l’onglet reste en lecture seule.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler") { wg.showSettings = false }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!url.isEmpty && (try? WGEasyAPI.baseURL(url)) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            url = wg.settings.apiURL.isEmpty ? (wg.webURL?.absoluteString ?? "") : wg.settings.apiURL
            user = wg.settings.apiUser
            container = wg.settings.container
            hours = wg.settings.watch.disconnectedHours
            days = wg.settings.watch.expiryDays
        }
    }

    private func save() {
        var settings = wg.settings
        settings.apiURL = url.isEmpty ? "" : ((try? WGEasyAPI.baseURL(url))?.absoluteString ?? settings.apiURL)
        settings.apiUser = user.trimmingCharacters(in: .whitespaces)
        if let name = try? RustDeskActionValidation.containerName(container.trimmingCharacters(in: .whitespaces)) { settings.container = name }
        settings.watch.disconnectedHours = hours
        settings.watch.expiryDays = days
        wg.settings = settings
        if !password.isEmpty { wg.setAPIPassword(password) }
        password = ""
        wg.showSettings = false
        wg.settingsChanged()
    }
}
