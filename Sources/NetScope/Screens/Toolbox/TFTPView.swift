import NetScopeCore
import SwiftUI

/// Outil « TFTP » (note 51) : serveur temporaire sur ce Mac (adresse à donner à l'appareil en
/// grand, dossier partagé, interface, port, accès, arrêt automatique, options RFC), client (get et
/// put vers un switch, une borne, un téléphone IP), journal en direct des transferts du site et
/// cas d'usage (sauvegarde de configuration, firmware, provisionnement des téléphones).
struct TFTPView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: TFTPModel
    @ObservedObject var store: ToolStore
    @StateObject private var journal = TFTPJournalTable.makeModel()
    @StateObject private var filesTable = TFTPFilesTable.makeModel()
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Choix serveur / client, état du serveur à droite (dessous en petite fenêtre).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modePicker
                    Spacer(minLength: 8)
                    runningChip
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    runningChip
                }
            }
            switch model.mode {
            case .serveur: TFTPServerSection(model: model)
            case .client: TFTPClientSection(model: model)
            }
            journalSection
            if model.mode == .serveur {
                SidePanelSplit(sideWidth: 380, collapse: .below, spacing: 16, collapseBelow: 820) {
                    TFTPFilesPanel(model: model, table: filesTable)
                } side: {
                    TFTPUseCases(model: model)
                }
            } else {
                TFTPUseCases(model: model)
            }
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Effacer l’historique TFTP de ce site\u{00A0}?", isPresented: $confirmingClear) {
            Button("Effacer l’historique", role: .destructive) { model.clearHistory() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les transferts terminés de «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}» sont retirés du journal. Les fichiers du dossier partagé ne sont pas touchés.")
        }
    }

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            ForEach(TFTPModel.Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var runningChip: some View {
        if model.isRunning {
            Chip(text: "Serveur en écoute · port \(model.listeningPort.map(String.init) ?? model.portText)", tone: .success,
                 systemImage: "dot.radiowaves.left.and.right")
        }
    }

    // MARK: Journal

    private var journalSection: some View {
        let rows = model.siteRecords.sorted(using: journal.sortOrder)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    journalTitle
                    Spacer(minLength: 8)
                    journalButtons(rows)
                }
                VStack(alignment: .leading, spacing: 6) {
                    journalTitle
                    HStack(spacing: 8) { journalButtons(rows) }
                }
            }
            TFTPJournalTable(rows: rows, table: journal)
        }
    }

    private var journalTitle: some View {
        HStack(spacing: 8) {
            ToolFieldLabel("Journal des transferts")
            Text("· \(SiteModel.shared.activeName)").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    @ViewBuilder private func journalButtons(_ rows: [TFTPTransferRecord]) -> some View {
                ToolColumnsMenu(model: journal)
                Button {
                    ToolActions.copy(rows.map(TFTPJournalTable.line).joined(separator: "\n"))
                } label: {
                    Label("Copier", systemImage: "doc.on.doc")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled(rows.isEmpty)
                Button { confirmingClear = true } label: {
                    Label("Effacer", systemImage: "trash")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled(rows.allSatisfy { $0.status == .running })
    }
}

// MARK: - Serveur

private struct TFTPServerSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: TFTPModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            stats
            settings
            notices
        }
        .alert("Autoriser l’écrasement des fichiers\u{00A0}?", isPresented: $model.confirmingOverwrite) {
            Button("Autoriser l’écrasement") { model.allowOverwrite = true }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Un appareil pourra remplacer un fichier du dossier «\u{00A0}\(model.rootName)\u{00A0}» (firmware, configuration) par le sien\u{00A0}: l’ancien fichier sera perdu. Sans cette case, un envoi vers un nom existant est refusé (erreur TFTP 6).")
        }
    }

    // MARK: Adresse et bouton

    private var address: String { model.macAddress(state: state)?.description ?? "—" }

    private var hero: some View {
        let running = model.isRunning
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                addressBlock.frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
                controlBlock(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 12) {
                addressBlock
                controlBlock(alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(running ? Theme.accentSoft : Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(running ? Theme.accent.opacity(0.5) : Theme.border))
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ToolFieldLabel("Adresse du Mac à donner à l’appareil")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(address)
                    .font(Theme.mono(28, weight: .bold))
                    .foregroundStyle(model.isRunning ? Theme.accentStrong : Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button {
                    ToolActions.copy(address)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .help("Copier l’adresse")
                if model.portText != "69" {
                    Text("port \(model.portText)").font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(detailLine).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        let interface = model.selectedInterface
        parts.append("UDP \(model.listeningPort.map(String.init) ?? model.portText)")
        if let interface {
            parts.append("\(interface.name) (\(interface.kind.label))")
        } else {
            let others = model.interfaces.filter { $0.address.description != address }
            parts.append(others.isEmpty ? "toutes les interfaces"
                         : "toutes les interfaces, aussi " + others.map { "\($0.address) (\($0.name))" }.joined(separator: ", "))
        }
        parts.append("dossier «\u{00A0}\(model.rootName)\u{00A0}»")
        parts.append(model.allowWrite ? (model.allowOverwrite ? "lecture, écriture et écrasement" : "lecture et écriture") : "lecture seule")
        return parts.joined(separator: " · ")
    }

    private func controlBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: {
                    Label("Arrêter le serveur", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
                .fixedSize()
            } else {
                Button { model.start(state: state) } label: {
                    Label("Démarrer le serveur", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .disabled(model.port == nil)
                .fixedSize()
            }
            Text(statusLine).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        guard model.isRunning else { return "Arrêté · jamais lancé tout seul" }
        var text = "En écoute depuis \(model.startedAt.map { ToolText.time($0) } ?? "—")"
        if model.activeTransfers > 0 {
            text += " · \(model.activeTransfers) transfert\(model.activeTransfers > 1 ? "s" : "") en cours"
        }
        if let remaining = model.remaining {
            text += model.activeTransfers > 0 ? "\nArrêt automatique \(model.autoStopMinutes)\u{00A0}min après le dernier transfert"
                : "\nArrêt automatique dans \(TFTPAutoStop.text(remaining))"
        } else {
            text += "\nPas d’arrêt automatique"
        }
        return text
    }

    // MARK: Bilan

    private var stats: some View {
        let session = model.siteRecords.filter { record in
            guard record.role == .server else { return false }
            if let started = model.startedAt { return record.date >= started }
            return Calendar.current.isDateInToday(record.date)
        }
        let done = session.filter { $0.status == .done }.count
        let problems = session.filter { $0.status == .failed || $0.status == .refused }.count
        let sent = session.filter { $0.flow == .toDevice }.reduce(Int64(0)) { $0 + $1.bytes }
        let received = session.filter { $0.flow == .fromDevice }.reduce(Int64(0)) { $0 + $1.bytes }
        let scope = model.startedAt == nil ? " aujourd’hui" : ""
        let tiles = [
            ("Transferts", "\(session.count)", "\(done) réussi\(done > 1 ? "s" : "")\(scope)", Theme.text),
            ("Erreurs et refus", "\(problems)", problems == 0 ? "aucun problème" : "voir le journal", problems > 0 ? Theme.warning : Theme.text),
            ("Envoyé aux appareils", TFTPFormat.bytes(sent), "fichiers lus (RRQ)", Theme.text),
            ("Reçu des appareils", TFTPFormat.bytes(received), "fichiers écrits (WRQ)", Theme.text),
        ]
        // Quatre cases sur une ligne ; deux par ligne en petite fenêtre.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(tiles, id: \.0) { tile in
                    ToolStatTile(label: tile.0, value: tile.1, detail: tile.2, valueColor: tile.3).frame(minWidth: 140)
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach([0, 2], id: \.self) { start in
                    GridRow {
                        ForEach(tiles[start..<start + 2], id: \.0) { tile in
                            ToolStatTile(label: tile.0, value: tile.1, detail: tile.2, valueColor: tile.3)
                        }
                    }
                }
            }
        }
    }

    // MARK: Réglages

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Dossier partagé") {
                    HStack(spacing: 6) {
                        Text(model.rootPath)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(model.rootPath)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 220, maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                        Button("Choisir…") { model.chooseRoot() }
                            .buttonStyle(.secondary)
                            .disabled(model.isRunning || model.isDemo)
                            .fixedSize()
                        Button { model.revealRoot() } label: { Image(systemName: "folder") }
                            .buttonStyle(.secondary)
                            .disabled(model.isDemo)
                            .help("Afficher dans le Finder")
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    ToolLabeledField(label: "Interface d’écoute") {
                        Picker("", selection: $model.interfaceName) {
                            Text("Toutes les interfaces").tag(String?.none)
                            ForEach(model.interfaces, id: \.name) { interface in
                                Text(verbatim: "\(interface.name) · \(interface.address.description) (\(interface.kind.label))").tag(String?.some(interface.name))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.large)
                        .fixedSize()
                    }
                    ToolLabeledField(label: "Port UDP") {
                        ToolTextField(placeholder: "69", text: $model.portText, invalid: model.port == nil, height: 28)
                            .frame(width: 76)
                    }
                }
            }
            .disabled(model.isRunning)
            ToolAdaptiveRow(spacing: 14) {
                ToolLabeledField(label: "Accès des appareils") {
                    Picker("", selection: $model.allowWrite) {
                        Text("Lecture seule").tag(false)
                        Text("Lecture et écriture").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolLabeledField(label: "Fichier existant") {
                    Toggle(isOn: Binding(get: { model.allowOverwrite && model.allowWrite }, set: { wanted in
                        if wanted { model.confirmingOverwrite = true } else { model.allowOverwrite = false }
                    })) {
                        Text("Écraser après confirmation").font(Theme.small)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!model.allowWrite)
                    .frame(height: 28)
                }
                ToolLabeledField(label: "Arrêt automatique") {
                    Picker("", selection: $model.autoStopMinutes) {
                        ForEach(TFTPModel.autoStopChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Jamais" : "Après \(minutes)\u{00A0}min sans transfert").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .disabled(model.isRunning)
            DisclosureGroup {
                ToolAdaptiveRow(spacing: 12) {
                    TFTPOptionPicker(label: "Bloc maximal (blksize)", selection: $model.maxBlockSize, choices: TFTPModel.blockSizeChoices) {
                        $0 == TFTPLimits.ethernetBlockSize ? "1468 (trame Ethernet)" : ($0 == 512 ? "512 (RFC 1350)" : "\($0)")
                    }
                    TFTPOptionPicker(label: "Fenêtre maximale", selection: $model.maxWindowSize, choices: TFTPModel.windowChoices) {
                        $0 == 1 ? "1 bloc" : "\($0) blocs"
                    }
                    TFTPOptionPicker(label: "Délai par défaut", selection: $model.timeout, choices: TFTPModel.timeoutChoices) { "\($0)\u{00A0}s" }
                    TFTPOptionPicker(label: "Essais", selection: $model.retries, choices: TFTPModel.retryChoices) { "\($0)" }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .disabled(model.isRunning)
                Text("Le serveur accepte les options demandées par l’appareil (RFC 2347 à 2349 et 7440) jusqu’à ces valeurs\u{00A0}: tsize (taille annoncée), blksize (gros blocs, firmwares rapides), timeout et windowsize. Mode binaire (octet) par défaut\u{00A0}; netascii accepté pour les fichiers texte.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text("Options RFC\u{00A0}: bloc \(model.maxBlockSize), fenêtre \(model.maxWindowSize), délai \(model.timeout)\u{00A0}s, \(model.retries) essais")
                    .font(Theme.bodyMedium).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Avertissements

    @ViewBuilder private var notices: some View {
        if let error = model.startError {
            ToolNotice(tone: .critical, title: "Démarrage impossible", message: error) {
                if model.portBusy {
                    Button("Utiliser le port \(String(TFTPModel.alternatePort))") { model.useAlternatePort() }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        }
        if let message = model.stopMessage {
            ToolNotice(tone: .neutral, message: message)
        }
        if let warning = model.firewall?.warning {
            ToolNotice(tone: .warning, title: "Coupe-feu de macOS", message: warning)
        }
        if !model.isRunning || model.portText != "69" {
            if model.port == 69 {
                ToolNotice(tone: .accent, title: "Port 69 sans droits administrateur",
                           message: "macOS réserve à l’administrateur l’écoute d’une adresse précise sous le port 1024, mais permet le port 69 sur toutes les interfaces\u{00A0}: NetScope écoute donc partout et ne répond qu’aux requêtes reçues sur l’interface choisie. Si le port 69 est déjà pris (serveur tftpd de macOS), prenez \(String(TFTPModel.alternatePort))\u{00A0}: l’appareil devra alors viser ce port (tftp://\(address):\(String(TFTPModel.alternatePort))/fichier).")
            } else if let port = model.port {
                ToolNotice(tone: .warning, title: "Port \(String(port))",
                           message: "L’appareil doit savoir viser ce port\u{00A0}: beaucoup de switchs et de téléphones IP utilisent toujours le port 69, sans réglage possible. Gardez 69 si l’appareil ne permet pas de choisir.")
            }
        }
        if model.allowWrite {
            ToolNotice(tone: .warning, title: "Écriture permise",
                       message: "Tant que le serveur tourne, tout appareil qui joint ce Mac peut déposer des fichiers dans «\u{00A0}\(model.rootName)\u{00A0}» (jamais hors de ce dossier, jamais «\u{00A0}../\u{00A0}»)" + (model.allowOverwrite ? " et remplacer ceux qui existent." : "\u{00A0}; un fichier existant n’est jamais écrasé."))
        }
        if !model.ignored.isEmpty {
            ToolNotice(tone: .neutral, title: "\(model.ignored.count) requête\(model.ignored.count > 1 ? "s" : "") ignorée\(model.ignored.count > 1 ? "s" : "")",
                       message: model.ignored.prefix(3).joined(separator: "\n"))
        }
    }
}

/// Choix d'une option (étiquette au-dessus, menu du système).
private struct TFTPOptionPicker: View {
    let label: String
    @Binding var selection: Int
    let choices: [Int]
    let text: (Int) -> String

    var body: some View {
        ToolLabeledField(label: label) {
            Picker("", selection: $selection) {
                ForEach(choices.contains(selection) ? choices : choices + [selection], id: \.self) { Text(text($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

// MARK: - Client

private struct TFTPClientSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: TFTPModel

    /// Appareils qui parlent souvent TFTP : switchs, bornes, téléphones IP, routeurs, imprimantes.
    private var targets: [Device] {
        let kinds: Set<DeviceType> = [.switch, .pointAcces, .telephoneIP, .routeur, .imprimante, .serveur]
        return state.devices.filter { kinds.contains($0.deviceType) && $0.ip != state.activeInterface?.address }
            .sorted { $0.ip < $1.ip }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Appareil") {
                    HStack(spacing: 6) {
                        ToolTextField(placeholder: "10.182.122.2", text: $model.clientHost,
                                      invalid: !model.clientHost.isEmpty && IPv4Address(model.clientHost.trimmingCharacters(in: .whitespaces)) == nil,
                                      height: 28)
                            .frame(minWidth: 150)
                        Menu {
                            if targets.isEmpty { Text("Aucun switch, borne ou téléphone dans le scan") }
                            ForEach(targets) { device in
                                Button("\(device.displayName) · \(device.ip.description) (\(device.deviceType.label))") {
                                    model.clientHost = device.ip.description
                                }
                            }
                        } label: {
                            Label("Appareils du scan", systemImage: "list.bullet")
                        }
                        .menuStyle(.button)
                        .controlSize(.large)
                        .fixedSize()
                    }
                }
                ToolLabeledField(label: "Port UDP") {
                    ToolTextField(placeholder: "69", text: $model.clientPortText,
                                  invalid: UInt16(model.clientPortText.trimmingCharacters(in: .whitespaces)) == nil, height: 28)
                        .frame(width: 76)
                }
                ToolLabeledField(label: "Opération") {
                    Picker("", selection: $model.clientDirection) {
                        Text("Récupérer (get)").tag(TFTPClient.Direction.get)
                        Text("Envoyer (put)").tag(TFTPClient.Direction.put)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(model.clientRunning)
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Fichier sur l’appareil") {
                    ToolTextField(placeholder: "startup-config", text: $model.remoteName, height: 28)
                        .frame(minWidth: 200)
                }
                ToolLabeledField(label: model.clientDirection == .get ? "Enregistrer sous" : "Fichier à envoyer") {
                    HStack(spacing: 6) {
                        Text(model.localPath.isEmpty ? "Aucun fichier choisi" : model.localPath)
                            .font(Theme.mono(12))
                            .foregroundStyle(model.localPath.isEmpty ? Theme.textTertiary : Theme.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(model.localPath)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 220, maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                        Button("Choisir…") { model.chooseLocalFile() }
                            .buttonStyle(.secondary)
                            .disabled(model.isDemo)
                            .fixedSize()
                    }
                }
            }
            .disabled(model.clientRunning)
            ToolAdaptiveRow(spacing: 12) {
                TFTPOptionPicker(label: "Taille de bloc", selection: $model.clientBlockSize, choices: TFTPModel.blockSizeChoices) {
                    $0 == TFTPLimits.ethernetBlockSize ? "1468 (trame Ethernet)" : ($0 == 512 ? "512 (RFC 1350)" : "\($0)")
                }
                TFTPOptionPicker(label: "Fenêtre", selection: $model.clientWindow, choices: TFTPModel.windowChoices) { $0 == 1 ? "1 bloc" : "\($0) blocs" }
                TFTPOptionPicker(label: "Délai", selection: $model.clientTimeout, choices: TFTPModel.timeoutChoices) { "\($0)\u{00A0}s" }
                TFTPOptionPicker(label: "Essais", selection: $model.clientRetries, choices: TFTPModel.retryChoices) { "\($0)" }
                ToolLabeledField(label: "Mode") {
                    Picker("", selection: $model.clientMode) {
                        ForEach(TFTPMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ToolLabeledField(label: "Options") {
                    Toggle(isOn: $model.clientUseOptions) { Text("Demander (RFC 2347)").font(Theme.small) }
                        .toggleStyle(.checkbox)
                        .frame(height: 22)
                        .help("Décochez pour un vieil appareil qui ne comprend que la RFC 1350 (blocs de 512 octets). Sans réponse aux options, NetScope repasse de lui-même en RFC 1350.")
                }
                Spacer(minLength: 0)
            }
            .disabled(model.clientRunning)
            HStack(spacing: 12) {
                if model.clientRunning {
                    Button(role: .destructive) { model.cancelClient() } label: { Label("Annuler", systemImage: "xmark") }
                        .buttonStyle(.secondary)
                        .fixedSize()
                } else {
                    Button { model.startClient(state: state) } label: {
                        Label(model.clientDirection == .get ? "Récupérer le fichier" : "Envoyer le fichier",
                              systemImage: model.clientDirection == .get ? "arrow.down.circle" : "arrow.up.circle")
                    }
                    .buttonStyle(.primary)
                    .fixedSize()
                }
                progress
            }
            if let result = model.clientResult {
                ToolNotice(tone: result.tone, title: result.title, message: result.message)
            }
            ToolNotice(tone: .accent, title: "L’appareil n’a pas de serveur TFTP\u{00A0}?",
                       message: "C’est le cas de la plupart des switchs, bornes et téléphones\u{00A0}: ce sont eux les clients. Démarrez plutôt le serveur de ce Mac (onglet «\u{00A0}Serveur sur ce Mac\u{00A0}») et lancez la copie depuis l’appareil, avec les commandes des cas d’usage ci-dessous.")
        }
    }

    @ViewBuilder private var progress: some View {
        let total = model.clientTotal
        if model.clientRunning || model.clientBytes > 0 {
            HStack(spacing: 10) {
                if let total, total > 0 {
                    ProgressBar(fraction: Double(model.clientBytes) / Double(total), color: Theme.accent, height: 6)
                        .frame(maxWidth: 260)
                } else if model.clientRunning {
                    ProgressView().controlSize(.small)
                }
                Text(progressText).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }

    private var progressText: String {
        let done = TFTPFormat.bytes(model.clientBytes)
        guard let total = model.clientTotal, total > 0 else { return done }
        return "\(done) sur \(TFTPFormat.bytes(total))" + (TFTPFormat.percent(model.clientBytes, of: total).map { " (\($0))" } ?? "")
    }
}

// MARK: - Fichiers du partage

private struct TFTPFilesPanel: View {
    @ObservedObject var model: TFTPModel
    @ObservedObject var table: StandardTableModel<TFTPSharedFile>

    var body: some View {
        let rows = model.files.sorted(using: table.sortOrder)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolFieldLabel("Fichiers servis")
                Text("· \(rows.count) dans «\u{00A0}\(model.rootName)\u{00A0}»").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
                Button { model.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .disabled(model.isDemo)
                    .help("Relire le dossier")
            }
            ToolStandardTableFrame(rowCount: rows.count, maxRows: 8,
                                   emptyText: "Dossier vide\u{00A0}: déposez-y le firmware ou les fichiers de configuration à servir.") {
                Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                    TableColumn("FICHIER", sortUsing: table.sort("fichier")) { file in
                        ToolTableText(file.path, size: 11)
                            .contextMenu { Button("Copier le nom") { ToolActions.copy(file.path) } }
                    }
                    .width(min: 140, ideal: 230)
                    .customizationID("fichier")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("TAILLE", sortUsing: table.sort("taille")) { file in
                        ToolTableText(TFTPFormat.bytes(file.size), size: 11, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80)
                    .customizationID("taille")
                    TableColumn("MODIFIÉ", sortUsing: table.sort("modifie")) { file in
                        ToolTableText(Self.date(file.modified), size: 11, mono: false, color: Theme.textSecondary)
                    }
                    .width(min: 70, ideal: 84)
                    .customizationID("modifie")
                }
            }
        }
    }
}

extension TFTPFilesPanel {
    /// « Auj. 19:28 », « Hier », « 2026-10-26 ».
    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return ToolText.day(date) }
        if calendar.isDateInYesterday(date) { return "Hier" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum TFTPFilesTable {
    static let columns: [StandardColumn] = [
        StandardColumn(id: "fichier", title: "Fichier", isRequired: true),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "modifie", title: "Modifié"),
    ]

    static let sortKeys: [String: KeyPathComparator<TFTPSharedFile>] = [
        "fichier": KeyPathComparator(\TFTPSharedFile.path),
        "taille": KeyPathComparator(\TFTPSharedFile.size),
        "modifie": KeyPathComparator(\TFTPSharedFile.modified),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<TFTPSharedFile> {
        StandardTableModel(id: "outils.tftp.fichiers", columns: columns, sortKeys: sortKeys, defaultSort: "fichier")
    }
}

// MARK: - Cas d'usage

private struct TFTPUseCases: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: TFTPModel

    private struct UseCase: Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let command: String
        var needsWrite = false
    }

    private var cases: [UseCase] {
        let ip = model.macAddress(state: state)?.description ?? "<ip-du-mac>"
        let host = model.portText == "69" ? ip : "\(ip):\(model.portText)"
        return [
            UseCase(title: "Sauvegarder la configuration d’un switch Cisco",
                    detail: "Le switch envoie sa configuration dans le dossier partagé.",
                    command: "copy running-config tftp://\(host)/SW-CORE-01-confg", needsWrite: true),
            UseCase(title: "Mettre à jour un switch HPE Aruba",
                    detail: "Déposez l’image .swi dans le dossier, puis sur le switch\u{00A0}:",
                    command: "copy tftp flash \(ip) WC_16_11_0012.swi primary"),
            UseCase(title: "FortiGate\u{00A0}: sauvegarde et firmware",
                    detail: "Configuration vers le Mac (écriture), ou image depuis le Mac.",
                    command: "execute backup config tftp fgt-bureau.conf \(ip)", needsWrite: true),
            UseCase(title: "Téléphones IP (Yealink, Poly, Cisco)",
                    detail: "Option DHCP 66 de la FortiGate vers ce Mac\u{00A0}; fichiers y000000000000.cfg et <MAC>.cfg dans le dossier.",
                    command: "set tftp-server \"\(ip)\""),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolFieldLabel("Cas d’usage")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(cases) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if item.needsWrite {
                                Chip(text: "écriture", tone: model.allowWrite ? .success : .warning)
                                    .help(model.allowWrite ? "Le serveur accepte l’écriture." : "Choisissez «\u{00A0}Lecture et écriture\u{00A0}» avant de démarrer le serveur.")
                            }
                        }
                        Text(item.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(item.command)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.consoleText)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Theme.console))
                                .help(item.command)
                            Button { ToolActions.copy(item.command) } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 11))
                            }
                            .buttonStyle(.secondary)
                            .controlSize(.small)
                            .help("Copier la commande")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}
