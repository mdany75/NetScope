import NetScopeCore
import SwiftUI

/// Écran `Screen.appareil` : fiche de l'appareil choisi (croquis docs/croquis/Device.dc.html).
struct DeviceScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var inventory = InvModel.shared

    var body: some View {
        if let device = state.selectedDevice {
            // Appareil ouvert hors Scanner (saisi à la main, repris de l'inventaire ou d'un autre site).
            let manual = state.manualEntry(forID: device.id)
            // Type choisi à la main (note 20) à la place du type détecté.
            DeviceDetailView(device: manual == nil ? inventory.withManualTypes([device])[0] : device, manual: manual)
                .id(device.id)
        } else {
            // « Ouvrir une fiche » : par IP, nom ou MAC, ou saisie à la main d'un appareil inconnu.
            DeviceLookupPanel()
        }
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    /// Appareil ouvert hors Scanner : saisi à la main, ou repris d'une fiche d'inventaire ou d'un autre site.
    var manual: ManualDeviceEntry? = nil
    @ObservedObject private var session = DeviceSession.shared
    @ObservedObject private var store = ToolStore.shared
    @ObservedObject private var notes = DeviceNotesStore.shared
    /// Emplacements relevés (note 18) : un ancien relevé est grisé comme dans le Scanner.
    @ObservedObject private var switches = SwitchStore.shared
    @State private var nameDraft = ""
    @State private var copied: String?
    /// Note 6 : retour du bouton « Connecter par RustDesk » (texte, erreur ?), effacé après quelques secondes.
    @State private var rustDeskMessage: (text: String, isError: Bool)?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                tabBar
                switch session.tab {
                case .apercu:
                    DeviceOverviewTab(device: device) { scanPorts() }
                case .ports:
                    DevicePortsTab(device: device, model: session.portModel(for: device), store: store)
                    // Note 72 : partages SMB quand le port 445 (ou 139) est ouvert, ou pour un NAS.
                    if SMBRelevance.isRelevant(openPorts: device.openPorts, vendor: device.vendor) {
                        SMBSharesPanel(host: device.ip.description, name: device.displayName)
                    }
                    // Note 69 : scan UDP ciblé (sondes propres à chaque protocole), sur clic.
                    UDPServicesPanel(host: device.ip.description, name: device.displayName)
                case .web:
                    DeviceWebTab(device: device, model: session.webModel(for: device), store: store)
                case .ressources:
                    DeviceResourcesTab(device: device)
                case .historique:
                    DeviceHistoryTab(device: device, store: store)
                case .notes:
                    DeviceNotesTab(device: device, notes: notes)
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            nameDraft = device.customName ?? ""
            state.recordDeviceView(device)
        }
        .screenToolbar {
            Button { step(-1) } label: { Label("Appareil précédent", systemImage: "chevron.up").labelStyle(.iconOnly) }
                .buttonStyle(.secondary).help("Appareil précédent de la liste").disabled(neighbor(-1) == nil)
            Button { step(1) } label: { Label("Appareil suivant", systemImage: "chevron.down").labelStyle(.iconOnly) }
                .buttonStyle(.secondary).help("Appareil suivant de la liste").disabled(neighbor(1) == nil)
            Button {
                copy(sheet, label: "Fiche copiée")
            } label: {
                Label("Copier la fiche", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.secondary)
            // Revient à « Ouvrir une fiche », comme si aucun appareil n'était choisi (Retour la rouvre).
            Button { state.closeDevice() } label: {
                Label("Fermer la fiche", systemImage: "xmark.circle")
            }
            .buttonStyle(.secondary)
            .help("Fermer la fiche et revenir à «\u{00A0}Ouvrir une fiche\u{00A0}»\u{00A0}; Retour la rouvre")
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.accentSoft)
                    Image(systemName: device.deviceType.toolSymbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        TextField("", text: $nameDraft, prompt: Text(device.hostnameLabel ?? device.ip.description).foregroundStyle(Theme.textTertiary))
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .focused($nameFocused)
                            .onSubmit(commitName)
                            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                            // Hauteur fixée : sans elle, un nom avec « œ » (« Switch cœur ») était coupé en bas.
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minHeight: 28)
                            .help("Nom personnalisé (vide\u{00A0}: nom d’hôte)")
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        statusChip
                    }
                    metaRow
                    HStack(spacing: 6) {
                        Menu {
                            if let manual {
                                // Appareil hors Scanner : le type est celui de la saisie.
                                ForEach(DeviceType.allCases, id: \.self) { type in
                                    Toggle(isOn: Binding(get: { manual.type == type }, set: { _ in
                                        var updated = manual
                                        updated.type = type
                                        state.updateManual(updated)
                                    })) {
                                        Label(type.label, systemImage: type.symbolName)
                                    }
                                }
                            } else {
                                DeviceTypeMenuItems(devices: [device])
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Chip(text: device.deviceType.label, tone: .accent, systemImage: device.deviceType.toolSymbol)
                                if manual == nil, InvModel.shared.typeChoice(for: state.device(withID: device.id) ?? device).isManual {
                                    ManualTypeMark()
                                }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Type de l’appareil\u{00A0}: cliquez pour le changer")
                        if let vlan = device.vlan {
                            let status = state.vlanStatus(device)
                            Chip(text: "VLAN \(vlan)", tone: .neutral).opacity(status.isCurrent ? 1 : 0.5).help(status.explanation ?? "")
                        }
                        if let range = device.rangeLabel { Chip(text: range, tone: .neutral) }
                        if device.mac?.isRandomized == true { Chip(text: "MAC privée", tone: .warning) }
                        if let port = device.switchLocation {
                            let status = state.locationStatus(device)
                            Chip(text: port, tone: .neutral, mono: true, systemImage: "cable.connector")
                                .opacity(status.isCurrent ? 1 : 0.5).help(status.explanation ?? "")
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            if let manual {
                DeviceManualBanner(entry: manual)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            if let notice = state.deviceNotice, notice.deviceID == device.id {
                HStack(spacing: 8) {
                    Label(notice.text, systemImage: "link")
                        .font(Theme.small).foregroundStyle(Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { state.deviceNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.ghost).help("Masquer")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                actions
                if let rustDeskMessage {
                    Label(rustDeskMessage.text, systemImage: rustDeskMessage.isError ? "exclamationmark.triangle" : "checkmark")
                        .font(Theme.caption)
                        .foregroundStyle(rustDeskMessage.isError ? Theme.warning : Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    @ViewBuilder private var statusChip: some View {
        if let manual, manual.lastCheck == nil {
            // Hors Scanner, jamais vérifié : ni en ligne, ni hors ligne (l'état d'une fiche reprise
            // est celui d'un autre scan ou de l'inventaire, pas du réseau actuel).
            HStack(spacing: 6) {
                StatusDot(online: false, size: 7)
                Text(manual.base.map { "Hors Scanner · vu \(ToolText.relative($0.lastSeen))" } ?? "Pas encore vérifié")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.neutralText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.neutralSoft))
            .fixedSize()
        } else {
            scannedStatusChip
        }
    }

    private var scannedStatusChip: some View {
        HStack(spacing: 6) {
            StatusDot(online: device.isOnline, size: 7)
            Text(device.isOnline
                 ? "En ligne" + (device.latencyMs.map { " · \(ToolFormat.milliseconds($0))" } ?? "")
                 : "Hors ligne · vu \(ToolText.relative(device.lastSeen))")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(device.isOnline ? Theme.success : Theme.neutralText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(device.isOnline ? Theme.successSoft : Theme.neutralSoft))
        .fixedSize()
    }

    /// Hostname, IP, MAC… : passent à la ligne en petite fenêtre au lieu d'être tronqués.
    private var metaRow: some View {
        FlowLayout(spacing: 16, lineSpacing: 4) {
            if let host = device.hostnameLabel { meta("Hostname", host + (device.nameSourceLabel.map { " · \($0)" } ?? "")) }
            meta("IP", device.ip.description)
            if let mac = device.mac { meta("MAC", mac.formatted(.upperColon)) }
            Text(device.vendorLabel).lineLimit(1)
            if let manual, manual.isTyped {
                Text("Saisi \(ToolText.relative(manual.created))").lineLimit(1)
            } else {
                Text("Vu \(ToolText.relative(device.lastSeen))").lineLimit(1)
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func meta(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .lineLimit(1)
    }

    /// Boutons d'action : une ligne si tout tient, sinon deux lignes de trois (jamais un bouton seul
    /// sur la deuxième ligne), et en dernier recours un passage à la ligne libre.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryActions
                secondaryActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { primaryActions }
                HStack(spacing: 8) { secondaryActions }
            }
            SwitchFlowLayout(spacing: 8, lineSpacing: 8) {
                primaryActions
                secondaryActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var primaryActions: some View {
        Button {
            state.sendToPing(device.ip.description)
        } label: {
            Label("Ping continu", systemImage: Screen.ping.symbol)
        }
        .buttonStyle(.primary)
        Button { scanPorts() } label: { Label("Scanner les ports", systemImage: "door.left.hand.open") }
            .buttonStyle(.secondary)
            // Note 69 : « Scanner les ports › UDP ciblé » au clic droit (TCP au clic).
            .contextMenu {
                Button("Ports TCP (profil choisi)") { scanPorts() }
                Button("UDP ciblé") { scanUDP() }
            }
            .help("Scanner les ports TCP du profil choisi (clic droit\u{00A0}: UDP ciblé)")
        Button {
            let wol = store.wol
            if let mac = device.mac { wol.macText = mac.formatted(.upperColon) }
            wol.selection = []
            if wol.broadcastText.isEmpty { wol.broadcastText = WakeOnLAN.defaultBroadcast(for: state.activeInterface).description }
            store.open(.wol, in: state)
        } label: {
            Label("Wake-on-LAN", systemImage: "power")
        }
        .buttonStyle(.secondary)
        .disabled(device.mac == nil)
    }

    /// Note 6 : message de « Connecter par RustDesk » sous les actions (RustDesk absent : l'alerte
    /// de téléchargement de la fenêtre principale s'en charge).
    private func showRustDesk(_ outcome: RemoteModel.RustDeskOutcome) {
        switch outcome {
        case .opened(let text): rustDeskMessage = (text, false)
        case .failed(let text): rustDeskMessage = (text, true)
        case .notInstalled: rustDeskMessage = nil; return
        }
        let shown = rustDeskMessage?.text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if rustDeskMessage?.text == shown { rustDeskMessage = nil }
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        Button { ToolActions.open(DeviceSession.defaultURL(for: device)) } label: {
            Label("Ouvrir dans le navigateur", systemImage: "safari")
        }
        .buttonStyle(.secondary)
        // Note 52 : l'utilisateur est demandé (feuille), puis retenu pour cet appareil.
        QuickLoginSSHButton(target: QuickLoginTarget(device: device)) { entry in
            Label(QuickLoginFormat.buttonTitle(entry), systemImage: "terminal")
        }
        .buttonStyle(.secondary)
        // Note 6 : ID RustDesk saisi dans la fiche d'inventaire de l'appareil.
        if let id = InvModel.shared.store.record(forIP: device.ip)?.annotations.validRustDeskID {
            Button {
                showRustDesk(RemoteModel.shared.connectRustDesk(id: id, name: device.displayName))
            } label: {
                Label("Connecter par RustDesk", systemImage: RemoteProtocol.rustdesk.symbol)
            }
            .buttonStyle(.secondary)
            .help("Connecter par RustDesk (ID \(RustDeskID.grouped(id)))")
            // Correctif 0.27.3 : l'onglet « Assistance RustDesk » d'Accès distant, ID déjà saisi.
            .contextMenu {
                Button("Connecter par RustDesk") {
                    showRustDesk(RemoteModel.shared.connectRustDesk(id: id, name: device.displayName))
                }
                Button("Ouvrir dans l’assistance RustDesk") {
                    RustDeskModel.shared.openAssistance(in: state, id: id)
                }
            }
        }
        // Note 50 : FTP, FTPS ou SFTP, actifs seulement si le port était ouvert au dernier scan.
        Menu {
            FileTransferOpenMenuItems(host: device.ip.description, name: device.displayName,
                                      openPorts: device.openPorts, deviceID: device.id)
        } label: {
            Label("Fichiers", systemImage: "folder").font(Theme.bodyMedium)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .frame(height: Theme.controlHeight)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .fixedSize()
        .help("Ouvrir l’appareil en FTP, FTPS ou SFTP dans Accès distant")
        // Note 51 : client TFTP prérempli (sauvegarde de configuration, firmware).
        Button { TFTPModel.shared.prepareClient(for: device, state: state) } label: {
            Label("TFTP", systemImage: ToolKind.tftp.symbol)
        }
        .buttonStyle(.secondary)
        .help("Envoyer ou récupérer un fichier par TFTP avec cet appareil")
        Menu {
            Button("Adresse IP") { copy(device.ip.description, label: "IP copiée") }
            if let mac = device.mac {
                Button("Adresse MAC") { copy(mac.formatted(.upperColon), label: "MAC copiée") }
            }
            if let host = device.hostname { Button("Nom d’hôte") { copy(host, label: "Nom copié") } }
            Divider()
            Button("Fiche complète") { copy(sheet, label: "Fiche copiée") }
        } label: {
            Label(copied ?? "Copier", systemImage: copied == nil ? "doc.on.doc" : "checkmark")
                .font(Theme.bodyMedium)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .frame(height: Theme.controlHeight)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .fixedSize()
    }

    // MARK: Onglets

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DeviceTab.allCases) { tab in
                let selected = session.tab == tab
                Button { session.tab = tab } label: {
                    HStack(spacing: 6) {
                        Text(tab.label)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                        if let count = count(for: tab) {
                            Text("\(count)")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Theme.neutralSoft))
                                .overlay(Capsule().strokeBorder(Theme.border))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? Theme.accent : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func count(for tab: DeviceTab) -> Int? {
        switch tab {
        case .ports:
            let model = session.portModel(for: device)
            let count = model.summary?.open.count ?? device.openPorts.count
            return count > 0 ? count : nil
        case .historique:
            let keys = [device.ip.description, device.mac?.formatted(.upperColon) ?? "", device.hostname ?? ""]
            // Mêmes événements que la chronologie (DeviceHistoryTab), réveils Wake-on-LAN compris.
            let wakes = device.mac.map { mac in store.wakeLog.filter { $0.mac == mac.formatted(.upperColon) }.count } ?? 0
            return 1 + store.recents(matching: keys).count + wakes + (device.lastSeen.timeIntervalSince(device.firstSeen) > 60 ? 1 : 0)
        default:
            return nil
        }
    }

    // MARK: Actions

    private func scanPorts() {
        session.tab = .ports
        DevicePortsTab.start(session.portModel(for: device), device: device, state: state, store: store)
    }

    /// Note 69 : scan UDP ciblé, résultats dans l'onglet Ports et services.
    private func scanUDP() {
        session.tab = .ports
        UDPScanModel.shared.scan(host: device.ip.description, store: store)
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (device.customName ?? "") else { return }
        if var entry = manual {
            entry.name = trimmed
            state.updateManual(entry)
            return
        }
        state.setCustomName(trimmed, for: device.id)
    }

    private func copy(_ text: String, label: String) {
        ToolActions.copy(text)
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = nil }
    }

    private func neighbor(_ offset: Int) -> Device? {
        guard let index = state.devices.firstIndex(where: { $0.id == device.id }) else { return nil }
        let target = index + offset
        return state.devices.indices.contains(target) ? state.devices[target] : nil
    }

    private func step(_ offset: Int) {
        if let next = neighbor(offset) { state.selectedDeviceID = next.id }
    }

    /// Fiche en texte (presse-papiers).
    private var sheet: String {
        var lines = ["\(device.displayName) — \(device.ip)"]
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { lines.append("\(key)\u{00A0}: \(value)") } }
        add("Nom d’hôte", device.hostname)
        add("MAC", device.mac?.formatted(.upperColon))
        add("Fabricant", device.vendorLabel)
        add("Famille", device.deviceType.label)
        add("État", device.isOnline ? "en ligne" : "hors ligne")
        add("Latence", device.latencyMs.map(ToolFormat.milliseconds))
        add("Emplacement", device.switchLocation)
        add("VLAN", device.vlan.map(String.init))
        add("Plage", device.rangeLabel)
        add("Ports ouverts", device.openPorts.isEmpty ? nil : device.openPorts.map(String.init).joined(separator: ", "))
        add("Première détection", DeviceFormat.date(device.firstSeen))
        add("Dernière détection", DeviceFormat.date(device.lastSeen))
        let note = notes.note(for: device)
        if !note.isEmpty { lines += ["", "Notes\u{00A0}:", note] }
        return lines.joined(separator: "\n")
    }
}
