import AppKit
import NetScopeCore
import SwiftUI

/// Note 78 : feuille « Transfert de fichier » de la console série : sens, protocole (XMODEM,
/// XMODEM-CRC, XMODEM-1K, YMODEM), fichiers à envoyer ou dossier de réception, conseils pour
/// l'appareil et durée estimée au débit du port.
struct SerialTransferSheet: View {
    @ObservedObject var session: TerminalSession
    /// Dessinée dans la page (captures) plutôt que dans une feuille.
    var inline = false
    let dismiss: () -> Void

    @State private var direction: SerialTransferController.Direction = .send
    @State private var proto: SerialFileProtocol = .xmodem1K
    @State private var files: [SerialFile]
    @State private var destination: URL
    @State private var error: String?

    init(session: TerminalSession, inline: Bool = false, files: [SerialFile] = [], dismiss: @escaping () -> Void) {
        self.session = session
        self.inline = inline
        self.dismiss = dismiss
        _files = State(initialValue: files)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        _destination = State(initialValue: session.isDemo ? URL(fileURLWithPath: "/Users/technicien/Downloads") : downloads)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down.square").foregroundStyle(Theme.accentStrong)
                    Text("Transfert de fichier").font(Theme.panelTitle)
                    Spacer()
                    Chip(text: "\(SerialPortInfo(path: session.serialPath).name) · \(session.serialSettings.summary)", tone: .neutral, mono: true)
                }
                Picker("Sens", selection: $direction) {
                    ForEach(SerialTransferController.Direction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                protocolPicker
                if direction == .send { sendFields } else { receiveFields }
                hints
                if let error { ToolNotice(tone: .critical, message: error) }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: inline ? 560 : nil)
        .frame(minWidth: 520, idealWidth: 560)
        .background(Theme.panel)
    }

    private var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Protocole")
            Picker("Protocole", selection: $proto) {
                ForEach(SerialFileProtocol.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(protocolHint).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protocolHint: String {
        switch proto {
        case .xmodem: return "Blocs de 128\u{00A0}octets\u{00A0}; à l’envoi, somme ou CRC selon l’appareil. Le plus compatible, le plus lent."
        case .xmodemCRC: return "Blocs de 128\u{00A0}octets avec CRC-16\u{00A0}: détecte mieux les erreurs de ligne."
        case .xmodem1K: return "Blocs de 1\u{00A0}Kio avec CRC-16\u{00A0}: le bon choix pour un firmware (ROMMON Cisco, chargeurs récents)."
        case .ymodem: return "Lot de fichiers\u{00A0}: nom et taille exacte transmis, blocs de 1\u{00A0}Kio avec CRC-16."
        }
    }

    // MARK: Envoi

    private var sendFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ToolFieldLabel(proto.isBatch ? "Fichiers à envoyer" : "Fichier à envoyer")
                Spacer()
                Button(proto.isBatch ? "Ajouter des fichiers…" : "Choisir le fichier…", action: chooseFiles)
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
            if shownFiles.isEmpty {
                Text("Aucun fichier choisi (64\u{00A0}Mio au plus par fichier).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(shownFiles.enumerated()), id: \.offset) { index, file in
                HStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(file.name).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(FileTransferFormat.size(Int64(file.data.count))).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                    Button {
                        files.removeAll { $0 == file }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Retirer ce fichier")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .accessibilityElement(children: .combine)
                .id(index)
            }
            if let estimate {
                Label(estimate, systemImage: "clock").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// XMODEM : un seul fichier (le premier).
    private var shownFiles: [SerialFile] { proto.isBatch ? files : Array(files.prefix(1)) }

    /// Durée au débit du port : 10 bits par octet en 8N1, plus l'en-tête et l'attente de chaque bloc.
    private var estimate: String? {
        let bytes = shownFiles.reduce(0) { $0 + $1.data.count }
        guard bytes > 0 else { return nil }
        let block = proto.usesLargeBlocks ? 1_024.0 : 128.0
        let overhead = (block + 5) / block
        let bitsPerByte = Double(session.serialSettings.dataBits + session.serialSettings.stopBits + 1
                                 + (session.serialSettings.parity == .none ? 0 : 1))
        let seconds = Double(bytes) * overhead * bitsPerByte / Double(max(session.serialSettings.baudRate, 300)) * 1.05
        var text = "Durée estimée à \(session.serialSettings.baudRate)\u{00A0}bauds\u{00A0}: environ \(FileTransferFormat.remaining(seconds))"
        if seconds > 600, session.serialSettings.baudRate < 115_200 {
            text += " (plus rapide à 115\u{00A0}200\u{00A0}bauds si l’appareil le permet)"
        }
        return text
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = proto.isBatch ? "Fichiers à envoyer par YMODEM" : "Fichier à envoyer par \(proto.shortLabel)"
        panel.prompt = "Choisir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = proto.isBatch
        guard panel.runModal() == .OK else { return }
        error = nil
        for url in panel.urls {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if let size = values.fileSize, size > XModem.maxReceiveSize {
                    error = "«\u{00A0}\(url.lastPathComponent)\u{00A0}» dépasse 64\u{00A0}Mio\u{00A0}: trop gros pour une console série (TFTP ou FTP conviennent mieux)."
                    continue
                }
                let data = try Data(contentsOf: url)
                let file = SerialFile(name: url.lastPathComponent, data: [UInt8](data), modified: values.contentModificationDate)
                if proto.isBatch { files.append(file) } else { files = [file] }
            } catch {
                self.error = "Lecture de «\u{00A0}\(url.lastPathComponent)\u{00A0}» impossible\u{00A0}: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Réception

    private var receiveFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Dossier de réception")
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                Text(destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choisir…", action: chooseFolder).buttonStyle(.secondary).controlSize(.small)
            }
            Text(proto.isBatch ? "YMODEM transmet les noms\u{00A0}: chaque fichier garde le sien (jamais d’écrasement)."
                               : "XMODEM ne transmet pas de nom\u{00A0}: le fichier sera «\u{00A0}console-<date>.bin\u{00A0}», sans le bourrage de fin (0x1A).")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Dossier où ranger les fichiers reçus"
        panel.prompt = "Choisir"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    // MARK: Conseils et pied

    private var hints: some View {
        let text = direction == .send
            ? "Lancez d’abord la réception sur l’appareil (ROMMON Cisco\u{00A0}: «\u{00A0}xmodem -c fichier.bin\u{00A0}», IOS\u{00A0}: «\u{00A0}copy xmodem: flash:\u{00A0}»), puis «\u{00A0}Démarrer\u{00A0}». NetScope attend la demande de l’appareil pendant 60\u{00A0}s."
            : "Cliquez «\u{00A0}Démarrer\u{00A0}», puis lancez l’envoi sur l’appareil (ex. «\u{00A0}copy flash:config.text xmodem:\u{00A0}»). NetScope demande les blocs pendant 60\u{00A0}s."
        return ToolNotice(tone: .accent, title: "Sur l’appareil", message: text + " Le clavier du terminal est suspendu pendant le transfert.") { EmptyView() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !session.isActive {
                Text("Ouvrez d’abord le port série.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button("Démarrer", action: begin)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canStart: Bool {
        session.phase == .connected && (direction == .receive || !shownFiles.isEmpty)
    }

    private func begin() {
        guard canStart else { return }
        let controller = SerialTransferController(direction: direction, proto: proto, files: direction == .send ? shownFiles : [],
                                                  destination: direction == .receive ? destination : nil, demo: session.isDemo)
        session.beginTransfer(controller)
        dismiss()
    }
}

/// Barre du transfert en cours (ou terminé) sous les réglages de la console série.
struct SerialTransferBar: View {
    @ObservedObject var controller: SerialTransferController
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: controller.direction == .send ? "arrow.up.doc" : "arrow.down.doc")
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(controller.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Chip(text: controller.state.isOver ? stateText : controller.state.label, tone: tone)
                    Text(controller.progress.checkLabel).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if controller.isActive {
                    if let fraction = controller.progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(controller.state.isOver ? controller.summary : controller.detail)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                if let saveError = controller.saveError {
                    Text(saveError).font(Theme.caption).foregroundStyle(Theme.critical).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if controller.isActive {
                Button("Annuler") { session.cancelTransfer() }
                    .buttonStyle(RemoteSmallButtonStyle(tint: Theme.critical))
                    .help("Arrête le transfert (CAN envoyés à l’appareil)")
            } else {
                if !controller.saved.isEmpty, !session.isDemo {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting(controller.saved) }
                        .buttonStyle(RemoteSmallButtonStyle())
                }
                Button("Fermer") { session.closeTransfer() }.buttonStyle(RemoteSmallButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var stateText: String {
        switch controller.state {
        case .finished: return "Terminé"
        case .failed: return "Échec"
        case .cancelled(let byPeer): return byPeer ? "Annulé par l’appareil" : "Annulé"
        default: return controller.state.label
        }
    }

    private var tone: Tone {
        switch controller.state {
        case .waiting: return .neutral
        case .transferring: return .accent
        case .finished: return .success
        case .failed: return .critical
        case .cancelled: return .warning
        }
    }

    private var iconColor: Color {
        switch controller.state {
        case .finished: return Theme.success
        case .failed: return Theme.critical
        case .cancelled: return Theme.warning
        default: return Theme.accentStrong
        }
    }
}
