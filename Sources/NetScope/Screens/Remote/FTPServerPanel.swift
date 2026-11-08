import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 50 : mini serveur FTP temporaire sur le Mac, pour les appareils qui viennent chercher leur
// fichier eux-mêmes (firmware d'un switch, configuration d'une borne ou d'un téléphone). Jamais
// lancé tout seul ; un compte, un mot de passe tiré au hasard (jamais enregistré) ; lecture seule
// par défaut ; arrêt automatique. En démonstration et pendant les captures : rien n'écoute.

@MainActor
final class FTPTemporaryServerModel: ObservableObject {
    static let shared = FTPTemporaryServerModel()

    @Published var isPresented = false
    @Published var folder: URL?
    @Published var port = "2121"
    @Published var user = "netscope"
    @Published var password = FTPTemporaryServerModel.randomPassword()
    @Published var allowWrite = false
    @Published var autoStopMinutes = 30
    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var events: [FTPMiniServer.Event] = []
    @Published var error: String?

    private var server: FTPMiniServer?
    private var stopTask: Task<Void, Never>?
    private let isSandboxed = RegEnvironment.isSandboxed

    private init() {
        if isSandboxed {
            folder = URL(fileURLWithPath: "/Users/dany/Downloads/Firmware")
            if ProcessInfo.processInfo.environment["NETSCOPE_REMOTE_VIEW"] == "serveur-ftp" {
                isPresented = true
                password = "kT7-mQ2-vX9"
                isRunning = true
                startedAt = FileTransferDemo.day(4, 10, 24)
                events = [
                    .init(date: FileTransferDemo.day(4, 10, 25), client: "10.182.122.3", text: "Connexion de netscope"),
                    .init(date: FileTransferDemo.day(4, 10, 25), client: "10.182.122.3", text: "Envoi de /ArubaOS-Switch_16.11.0013.swi"),
                    .init(date: FileTransferDemo.day(4, 10, 27), client: "10.182.122.40", text: "Identification refusée (admin)"),
                ]
            }
        }
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let groups = (0..<3).map { _ in String((0..<3).map { _ in alphabet.randomElement()! }) }
        return groups.joined(separator: "-")
    }

    /// Adresses du Mac à donner à l'appareil.
    func addresses(_ state: AppState) -> [String] {
        if isSandboxed { return ["10.182.122.135"] }
        return [state.activeInterface?.address.description].compactMap { $0 }
    }

    func chooseFolder() {
        guard !isSandboxed else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Partager"
        panel.message = "Dossier offert par le serveur FTP temporaire (rien au-dessus ne sera visible)."
        if panel.runModal() == .OK { folder = panel.url }
    }

    func start() {
        error = nil
        guard let folder else { error = "Choisissez le dossier à partager."; return }
        guard let portValue = UInt16(port.trimmingCharacters(in: .whitespaces)), portValue > 0 else {
            error = "Port invalide (1 à 65535)."
            return
        }
        guard (try? RemoteValidator.validateUser(user)) != nil, !user.isEmpty, !password.isEmpty else {
            error = "Utilisateur ou mot de passe invalide."
            return
        }
        if isSandboxed {
            isRunning = true
            startedAt = Date()
            events = [.init(date: Date(), client: "—", text: "Démonstration\u{00A0}: aucun port n’est ouvert.")]
            return
        }
        let configuration = FTPMiniServer.Configuration(root: folder, port: portValue, user: user, password: password,
                                                        allowWrite: allowWrite)
        let server = FTPMiniServer(configuration: configuration) { event in
            Task { @MainActor in
                let model = FTPTemporaryServerModel.shared
                model.events.insert(event, at: 0)
                if model.events.count > 200 { model.events.removeLast() }
            }
        }
        self.server = server
        Task {
            do {
                _ = try await server.start()
                isRunning = true
                startedAt = Date()
                events.insert(.init(date: Date(), client: "—", text: "Serveur démarré sur le port \(portValue)"), at: 0)
                scheduleStop()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.server = nil
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        server?.stop()
        server = nil
        if isRunning { events.insert(.init(date: Date(), client: "—", text: "Serveur arrêté"), at: 0) }
        isRunning = false
        startedAt = nil
    }

    private func scheduleStop() {
        stopTask?.cancel()
        let minutes = autoStopMinutes
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
            self?.events.insert(.init(date: Date(), client: "—", text: "Arrêt automatique après \(minutes)\u{00A0}min"), at: 0)
        }
    }
}

/// Encadré de l'aperçu d'Accès distant qui ouvre le serveur temporaire.
struct FTPServerCard: View {
    @ObservedObject private var server = FTPTemporaryServerModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 14)).foregroundStyle(Theme.textSecondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Serveur FTP temporaire").font(.system(size: 12, weight: .semibold))
                    if server.isRunning { Chip(text: "En marche", tone: .success) }
                }
                Text("Offre un dossier du Mac aux appareils qui viennent chercher leur fichier (firmware, configuration).")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionRow {
                    Button(server.isRunning ? "Afficher" : "Ouvrir…") { server.isPresented = true }
                        .buttonStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Fenêtre du serveur temporaire (par-dessus Accès distant, comme l'import du scan).
struct FTPServerOverlay: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var server = FTPTemporaryServerModel.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .shadowColor).opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { server.isPresented = false }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Serveur FTP temporaire").font(Theme.panelTitle)
                        Text("Un dossier du Mac, offert le temps d’un transfert\u{00A0}; rien au-dessus n’est visible.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        server.isPresented = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.ghost)
                    .help("Fermer (le serveur continue s’il est en marche)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if server.isRunning { runningBox }
                        settings
                        SpeedBanner(text: "FTP n’est pas chiffré\u{00A0}: n’offrez que des fichiers sans secret, sur le réseau local, et arrêtez le serveur après le transfert. Le pare-feu de macOS peut demander d’autoriser NetScope à recevoir des connexions.")
                        if let error = server.error {
                            SpeedBanner(text: error, tone: .critical, systemImage: "xmark.octagon")
                        }
                        journal
                    }
                    .padding(16)
                }
                .frame(maxHeight: 520)

                HStack(spacing: 10) {
                    Text(server.isRunning ? "Arrêt automatique après \(server.autoStopMinutes)\u{00A0}min" : "Le serveur ne démarre jamais tout seul.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if server.isRunning {
                        Button("Arrêter le serveur") { server.stop() }.buttonStyle(.primary)
                    } else {
                        Button("Démarrer") { server.start() }.buttonStyle(.primary).disabled(server.folder == nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.panelMuted)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.25), radius: 20, y: 16)
            .padding(.top, 40)
            .padding(.horizontal, 16)
        }
    }

    private var runningBox: some View {
        let address = server.addresses(state).first ?? "adresse du Mac"
        return VStack(alignment: .leading, spacing: 6) {
            Text("À saisir sur l’appareil").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Text("ftp://\(address):\(server.port)/").font(Theme.mono(16, weight: .semibold)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ftp://\(address):\(server.port)/", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.ghost)
                .help("Copier l’adresse")
            }
            Text("Utilisateur \(server.user) · mot de passe \(server.password) · \(server.allowWrite ? "lecture et écriture" : "lecture seule")")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.neutralText).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                label("Dossier partagé")
                HStack(spacing: 6) {
                    Text(server.folder?.path ?? "Aucun dossier choisi").font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                    Button("Choisir…") { server.chooseFolder() }.buttonStyle(RemoteSmallButtonStyle())
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Port")
                    RemoteInput(placeholder: "2121", text: $server.port)
                }
                .frame(width: 90)
                VStack(alignment: .leading, spacing: 4) {
                    label("Utilisateur")
                    RemoteInput(placeholder: "netscope", text: $server.user, mono: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Mot de passe (tiré au hasard)")
                    HStack(spacing: 4) {
                        RemoteInput(placeholder: "", text: $server.password)
                        Button {
                            server.password = FTPTemporaryServerModel.randomPassword()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.ghost)
                        .help("Tirer un autre mot de passe")
                    }
                }
            }
            .disabled(server.isRunning)
            HStack(spacing: 16) {
                Toggle("Permettre l’envoi vers le Mac (écriture)", isOn: $server.allowWrite).toggleStyle(.checkbox).font(Theme.small)
                Picker("Arrêt automatique", selection: $server.autoStopMinutes) {
                    ForEach([10, 30, 60, 120], id: \.self) { Text("\($0)\u{00A0}min").tag($0) }
                }
                .font(Theme.small)
                .fixedSize()
            }
            .disabled(server.isRunning)
        }
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Journal")
            if server.events.isEmpty {
                Text("Les connexions et les fichiers demandés apparaîtront ici.").font(Theme.small).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(server.events.prefix(40).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Text(RemoteFormat.time(event.date)).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                            Text(event.client).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                            Text(event.text).font(Theme.small).lineLimit(1)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
    }
}
