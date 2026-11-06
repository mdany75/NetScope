import AppKit
import NetScopeCore
import SwiftUI

/// Emplacement à ajouter ou à modifier (feuille « Ajouter un emplacement… », note 55).
struct DiskShareDraft: Identifiable {
    var share: DiskShareLocation
    var isNew: Bool
    /// Résultat de « Tester le serveur » préparé (captures seulement).
    var report: DiskServerReport?

    var id: UUID { share.id }
}

/// Feuille d'ajout d'un NAS, d'un partage SMB, NFS, AFP ou WebDAV, ou d'un dossier quelconque :
/// type, serveur (saisi ou appareil du Scanner ou de l'Inventaire), partage, compte et mot de passe
/// (Trousseau), « Tester le serveur ». Note 78 : FTP, FTPS et SFTP aussi (mesurés par le client
/// de transfert, sans montage). Rien n'est enregistré avant « Ajouter » ou « Enregistrer ».
struct DiskShareSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: DiskSpeedModel
    let dismiss: () -> Void
    /// Dessinée dans la page (captures) plutôt que dans une feuille : sans défilement propre.
    var inline = false

    private let isNew: Bool
    private let original: DiskShareLocation
    @State private var draft: DiskShareLocation
    @State private var pasted = ""
    @State private var pasteFailed = false
    @State private var portText: String
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var report: DiskServerReport?
    @State private var reportKey: String?
    @State private var testing = false
    @State private var error: String?

    init(model: DiskSpeedModel, draft: DiskShareDraft, inline: Bool = false, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        self.inline = inline
        isNew = draft.isNew
        original = draft.share
        _draft = State(initialValue: draft.share)
        _portText = State(initialValue: draft.share.port.map(String.init) ?? "")
        _report = State(initialValue: draft.report)
        _reportKey = State(initialValue: draft.report.map { _ in Self.reportKey(draft.share) })
    }

    // MARK: Brouillon

    private var portValue: Int? {
        let text = portText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Int(text) ?? -1
    }

    private var current: DiskShareLocation {
        var share = draft
        share.port = draft.kind == .webdav || draft.kind.isFileTransfer ? portValue : nil
        return share
    }

    private var problems: [String] { current.problems }
    private var canSave: Bool { problems.isEmpty && draft.kind.isAvailable }

    /// Le résultat affiché correspond encore au serveur, au type et au port saisis.
    private static func reportKey(_ share: DiskShareLocation) -> String {
        "\(share.kind.rawValue)|\(share.trimmedServer.lowercased())|\(share.port ?? 0)|\(share.secure)"
    }

    private var shownReport: DiskServerReport? { reportKey == Self.reportKey(current) ? report : nil }

    // MARK: Vue

    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 0) {
                form
                Divider()
                footer
            }
            // Capture : la feuille suit la largeur de l'outil (petite fenêtre) sans dépasser 620.
            .frame(maxWidth: 620)
            .background(Theme.panel)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { form }
                Divider()
                footer
            }
            .frame(minWidth: 560, idealWidth: 620, maxWidth: 720, minHeight: 420, idealHeight: 640)
            .background(Theme.panel)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: draft.kind.symbol).foregroundStyle(Theme.accentStrong)
                Text(isNew ? "Ajouter un emplacement" : "Modifier «\u{00A0}\(original.displayName)\u{00A0}»").font(Theme.panelTitle)
                Spacer()
                Chip(text: "Site\u{00A0}: \(SiteModel.shared.name(forKey: draft.siteKey))", tone: .neutral, systemImage: "building.2")
            }
            kindPicker
            if draft.kind == .dossier {
                folderFields
            } else {
                pasteField
                serverFields
                if draft.kind.usesCredentials { credentialFields }
                addressPreview
                testBox
            }
            if let error {
                ToolNotice(tone: .critical, message: error)
            }
        }
        .padding(20)
    }

    // MARK: Type

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Type")
            ToolFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(DiskShareKind.ordered) { kind in
                    ToolChoiceChip(label: kind == .dossier ? "Autre (dossier)" : kind.label, isSelected: draft.kind == kind, mono: false) {
                        choose(kind)
                    }
                    .help(kind.title)
                }
            }
            Text(hint(for: draft.kind))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(for kind: DiskShareKind) -> String {
        switch kind {
        case .smb: return "NAS (Synology, QNAP…), serveur Windows ou Mac\u{00A0}: le plus courant."
        case .nfs: return "Export NFS d’un NAS ou d’un serveur Linux\u{00A0}: pas de mot de passe, l’accès dépend de l’adresse de ce Mac."
        case .afp: return "Ancien partage Apple (Time Capsule, vieux NAS)."
        case .webdav: return "Nextcloud, ownCloud, SharePoint ou NAS en WebDAV (HTTPS de préférence)."
        case .dossier: return "N’importe quel dossier visible dans le Finder\u{00A0}: sous-dossier d’un disque, d’un partage déjà monté, volume chiffré…"
        case .ftp: return "Serveur FTP (NAS, caméra, ancien serveur)\u{00A0}: fichier d’essai envoyé puis reçu, rien n’est monté. FTP en clair\u{00A0}: réseau local seulement."
        case .ftps: return "FTP chiffré par TLS\u{00A0}: port 21 (TLS explicite) ou 990 (TLS implicite)."
        case .sftp: return "Transfert par SSH (NAS, serveur Linux)\u{00A0}: mot de passe au Trousseau, ou clés de ~/.ssh sans mot de passe."

        }
    }

    private func choose(_ kind: DiskShareKind) {
        if kind == .dossier, draft.kind != .dossier { draft.share = "" }
        if draft.kind == .dossier, kind != .dossier { draft.share = "" }
        if kind == .nfs, !draft.share.isEmpty, !draft.share.hasPrefix("/") { draft.share = "/" + draft.share }
        draft.kind = kind
    }

    // MARK: Partage réseau

    private var pasteField: some View {
        ToolLabeledField(label: "Coller une adresse (facultatif)") {
            HStack(spacing: 6) {
                ToolTextField(placeholder: draft.kind.isFileTransfer ? "\(draft.kind.rawValue)://serveur/chemin" : "smb://serveur/partage, \\\\serveur\\partage, serveur:/export", text: $pasted,
                              invalid: pasteFailed, height: 28, onSubmit: applyPaste)
                    .onChange(of: pasted) { _, _ in pasteFailed = false }
                Button("Remplir", action: applyPaste)
                    .buttonStyle(.secondary)
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func applyPaste() {
        guard let address = DiskShareAddress.parse(pasted) else {
            pasteFailed = !pasted.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        error = nil
        draft.kind = address.kind
        if address.kind == .dossier {
            draft.share = address.share
        } else {
            draft.server = address.server
            draft.share = address.share
            if !address.user.isEmpty { draft.user = address.user }
            draft.secure = address.secure
            portText = address.port.map(String.init) ?? ""
            draft.deviceName = nil
            draft.deviceIP = nil
            draft.deviceHost = nil
        }
        pasted = ""
    }

    private var serverFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolAdaptiveRow(spacing: 10) {
                ToolLabeledField(label: "Serveur (nom ou IP)") {
                    HStack(spacing: 6) {
                        ToolTextField(placeholder: "nas-bureau.local ou 10.10.0.31", text: Binding(get: { draft.server }, set: { value in
                            draft.server = value
                            // Saisie à la main : l'appareil choisi ne correspond plus.
                            if value != draft.deviceIP { draft.deviceName = nil; draft.deviceIP = nil; draft.deviceHost = nil }
                        }), invalid: !draft.server.isEmpty && !DiskShareAddress.isValidHost(draft.trimmedServer), height: 28)
                        deviceMenu
                    }
                }
                .frame(minWidth: 280)
                if draft.kind.isFileTransfer {
                    ToolLabeledField(label: "Port") {
                        ToolTextField(placeholder: String(draft.kind.ports().first ?? 21), text: $portText,
                                      invalid: portValue.map { !(1...65_535).contains($0) } ?? false, height: 28)
                            .frame(width: 80)
                    }
                }
                if draft.kind == .webdav {
                    ToolLabeledField(label: "Port") {
                        ToolTextField(placeholder: draft.secure ? "443" : "80", text: $portText,
                                      invalid: portValue.map { !(1...65_535).contains($0) } ?? false, height: 28)
                            .frame(width: 80)
                    }
                    ToolLabeledField(label: "Chiffrement") {
                        Toggle("HTTPS", isOn: $draft.secure).toggleStyle(.checkbox).frame(height: 28)
                    }
                    .fixedSize()
                }
            }
            if let name = draft.deviceName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.system(size: 11))
                    Text("Appareil\u{00A0}: \(name)" + (draft.deviceHost.map { " · \($0)" } ?? "") + (draft.deviceIP.map { " · \($0)" } ?? ""))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            ToolAdaptiveRow(spacing: 10) {
                ToolLabeledField(label: draft.kind.shareLabel) {
                    ToolTextField(placeholder: draft.kind.sharePlaceholder, text: $draft.share, height: 28)
                }
                .frame(minWidth: 220)
                ToolLabeledField(label: "Nom affiché (facultatif)") {
                    ToolTextField(placeholder: current.displayName, text: $draft.name, mono: false, height: 28)
                }
                .frame(minWidth: 200)
            }
        }
    }

    /// Appareils du Scanner et de l'Inventaire du site, serveurs de fichiers d'abord.
    private var candidates: [DiskShareCandidate] {
        DiskShareCandidate.list(devices: state.devices, records: InvModel.shared.store.sortedRecords,
                                excluding: state.activeInterface?.address.description)
    }

    private var deviceMenu: some View {
        let list = candidates
        let sharing = list.filter { !$0.shareServices.filter { $0 != "Web" }.isEmpty }
        let others = list.filter { $0.shareServices.filter { $0 != "Web" }.isEmpty }.prefix(30)
        return Menu {
            if list.isEmpty { Text("Aucun appareil\u{00A0}: lancez un scan") }
            if !sharing.isEmpty {
                Section("Partages détectés") {
                    ForEach(sharing) { device in deviceButton(device) }
                }
            }
            if !others.isEmpty {
                Section("Autres appareils") {
                    ForEach(Array(others)) { device in deviceButton(device) }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 28)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .help("Choisir un appareil du Scanner ou de l’Inventaire")
    }

    private func deviceButton(_ device: DiskShareCandidate) -> some View {
        let services = device.shareServices.joined(separator: ", ")
        return Button("\(device.name) · \(device.ip)" + (services.isEmpty ? "" : " · \(services)") + (device.isOnline ? "" : " · hors ligne")) {
            pick(device)
        }
    }

    private func pick(_ device: DiskShareCandidate) {
        draft.server = device.ip
        draft.deviceName = device.name
        draft.deviceIP = device.ip
        draft.deviceHost = device.host
        // Type proposé d'après les ports vus par le scan, si celui choisi n'y est pas.
        if let suggestion = DiskShareKind.suggested(openPorts: device.openPorts),
           Set(device.openPorts).isDisjoint(with: draft.kind.ports(secure: draft.secure)) {
            choose(suggestion.kind)
            draft.secure = suggestion.secure
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolAdaptiveRow(spacing: 10) {
                ToolLabeledField(label: "Utilisateur") {
                    ToolTextField(placeholder: userPlaceholder,
                                  text: $draft.user, height: 28)
                }
                .frame(minWidth: 220)
                ToolLabeledField(label: "Mot de passe") {
                    SecureField("", text: Binding(get: { password }, set: { password = $0; passwordChanged = true }),
                                prompt: Text(draft.hasPassword && !passwordChanged ? "•••••••• (au Trousseau)" : "Mot de passe"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .disabled(draft.trimmedUser.isEmpty)
                }
                .frame(minWidth: 200)
            }
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Text(credentialNote)
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if draft.hasPassword && !passwordChanged {
                    Button("Effacer") { password = ""; passwordChanged = true }
                        .buttonStyle(.link).controlSize(.small).font(Theme.caption)
                }
            }
        }
    }

    private var userPlaceholder: String {
        switch draft.kind {
        case .smb: return "technicien ou BUREAU;technicien (vide\u{00A0}: invité)"
        case .ftp, .ftps: return "technicien (vide\u{00A0}: anonyme)"
        default: return "technicien"
        }
    }

    private var credentialNote: String {
        if draft.trimmedUser.isEmpty {
            return draft.kind.isFileTransfer && draft.kind != .sftp ? "Sans utilisateur, NetScope se connecte en anonyme."
                : "Sans utilisateur, NetScope se connecte en invité."
        }
        if draft.kind == .sftp {
            return "Mot de passe gardé dans le Trousseau de macOS\u{00A0}; sans mot de passe, les clés de ~/.ssh et l’agent SSH."
        }
        return "Mot de passe gardé dans le Trousseau de macOS, jamais en clair ni dans les fichiers de NetScope."
    }

    private var addressPreview: some View {
        HStack(spacing: 6) {
            Text(draft.kind.isFileTransfer ? "Adresse" : "Adresse de montage").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(current.mountURL?.absoluteString.removingPercentEncoding ?? "—")
                .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.text)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Tester le serveur

    private var testBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    runTest()
                } label: {
                    Label("Tester le serveur", systemImage: "stethoscope")
                }
                .buttonStyle(.secondary)
                .disabled(testing || current.trimmedServer.isEmpty || !DiskShareAddress.isValidHost(current.trimmedServer))
                if testing { ProgressView().controlSize(.small) }
                Text("Ping et ports " + DiskServerCheck.portList(kind: current.kind, customPort: current.port))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            if let report = shownReport {
                DiskServerReportView(report: report, kind: draft.kind, secure: draft.secure, customPort: current.port) { kind in
                    choose(kind)
                    reportKey = Self.reportKey(current)
                }
            }
        }
    }

    private func runTest() {
        let share = current
        testing = true
        Task {
            let result = await model.checkServer(host: share.trimmedServer, kind: share.kind, customPort: share.port)
            report = result
            reportKey = Self.reportKey(share)
            testing = false
        }
    }

    // MARK: Dossier

    private var folderFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolLabeledField(label: "Dossier") {
                HStack(spacing: 6) {
                    ToolTextField(placeholder: DiskShareKind.dossier.sharePlaceholder, text: $draft.share, height: 28)
                    Button("Choisir…", action: chooseFolder).buttonStyle(.secondary)
                }
            }
            ToolLabeledField(label: "Nom affiché (facultatif)") {
                ToolTextField(placeholder: current.displayName, text: $draft.name, mono: false, height: 28)
            }
            Text("Le fichier d’essai est écrit dans «\u{00A0}NetScope-test\u{00A0}», à l’intérieur de ce dossier, puis supprimé.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier à mesurer"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if draft.share.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: draft.share, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.share = url.path
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 8) {
            if let first = problems.first {
                Text(first).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else if !isNew, draft.hasPassword {
                Text("Trousseau\u{00A0}: com.danymenard.netscope.partages").font(Theme.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(isNew ? "Ajouter" : "Enregistrer", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func save() {
        guard canSave else { return }
        if let message = model.save(current, password: password, passwordChanged: passwordChanged) {
            error = message
            return
        }
        dismiss()
    }
}

/// Résultat de « Tester le serveur » : bilan en clair, ping et état de chaque port.
struct DiskServerReportView: View {
    let report: DiskServerReport
    let kind: DiskShareKind
    var secure = true
    var customPort: Int?
    /// « Utiliser NFS » quand un autre service répond (feuille seulement).
    var onUseKind: ((DiskShareKind) -> Void)?

    var body: some View {
        let assessment = report.assessment(kind: kind, secure: secure, customPort: customPort)
        VStack(alignment: .leading, spacing: 8) {
            ToolNotice(tone: Self.tone(assessment.tone), title: assessment.title, message: assessment.detail) {
                if let suggested = assessment.suggested, let onUseKind {
                    Button("Utiliser \(suggested.label)") { onUseKind(suggested) }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            ToolFlowLayout(spacing: 6, lineSpacing: 6) {
                Chip(text: report.address.map { $0 == report.host ? $0 : "\(report.host) → \($0)" } ?? "\(report.host) introuvable",
                     tone: report.address == nil ? .critical : .neutral, mono: true, systemImage: "network")
                Chip(text: report.pingMs.map { "ping \(DiskFormat.latency($0))" } ?? "ping sans réponse",
                     tone: report.pingMs == nil ? .warning : .success, mono: true, systemImage: "dot.radiowaves.left.and.right")
                ForEach(report.ports, id: \.port) { port in
                    Chip(text: "\(port.port) \(DiskServerCheck.serviceName(port.port)) · \(port.state.label)",
                         tone: Self.tone(port.state), mono: false)
                        .help(port.rttMs.map { "Connexion en \(DiskFormat.latency($0))" } ?? port.state.label)
                }
            }
        }
    }

    static func tone(_ state: PortState) -> Tone {
        switch state {
        case .open: return .success
        case .closed: return .neutral
        case .filtered: return .neutral
        }
    }

    static func tone(_ tone: DiskVerdict.Tone) -> Tone {
        switch tone {
        case .success: return .success
        case .accent: return .accent
        case .warning: return .warning
        case .critical: return .critical
        case .neutral: return .neutral
        }
    }
}
