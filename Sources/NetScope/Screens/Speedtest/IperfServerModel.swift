import Foundation
import NetScopeCore
import SwiftUI

/// Note 78 : moteur d'un test iperf3 lancé depuis ce Mac.
enum IperfEngine: String, CaseIterable, Identifiable {
    /// Client écrit dans NetScope : rien à installer (TCP, sens normal ou inverse).
    case integre
    /// iperf3 de Homebrew (UDP et bidirectionnel en plus).
    case iperf3

    var id: String { rawValue }

    var label: String { self == .integre ? "Intégré" : "iperf3" }
}

/// Note 78 : serveur iperf3 intégré (« iperf3 -s » sans rien installer). Démarré seulement sur un
/// clic, arrêté par l'utilisateur ou automatiquement après un délai sans test ; un test à la
/// fois. En démonstration et pendant les captures, rien n'écoute : l'état et les tests affichés
/// sont fictifs (DevTools/IperfServerDemo.swift).
@MainActor
final class IperfServerModel: ObservableObject {
    static let shared = IperfServerModel()

    enum RunState: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    /// Délais d'arrêt automatique proposés (minutes sans test).
    static let autoStopChoices = [5, 15, 30, 60]
    /// Tests gardés dans la liste (non enregistrés : ils disparaissent à la fermeture de l'app).
    static let keptTests = 20

    /// Vue « Serveur de ce Mac » de l'outil iperf3 (sinon la vue Client).
    @Published var showServer = false
    @Published var portText = String(IperfProtocol.defaultPort)
    @Published var autoStopMinutes = 15 {
        didSet { if isListening { stopAt = Date().addingTimeInterval(Double(autoStopMinutes) * 60) } }
    }
    @Published private(set) var runState: RunState = .stopped
    /// Test en cours (intervalles en direct).
    @Published private(set) var current: IperfServerTest?
    @Published private(set) var tests: [IperfServerTest] = []
    /// Heure de l'arrêt automatique (repoussée à la fin de chaque test).
    @Published private(set) var stopAt: Date?
    /// Dernier message (refus, échec, arrêt automatique).
    @Published var notice: String?

    private var server: IperfServer?
    /// Jeton du serveur en cours (événements des anciens serveurs ignorés).
    private var serverToken: UUID?
    /// Arrêt de l'ancien serveur en cours (hors du fil principal) : il libère encore le port.
    private var stopping: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let demo = Launcher.isDemo || CommandLine.arguments.contains("--snapshot")

    private init() {
        if demo { IperfServerDemo.apply(to: self) }
    }

    var isListening: Bool {
        if case .listening = runState { return true }
        return false
    }

    var port: UInt16? { UInt16(portText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

    /// Commande à taper sur l'autre appareil (« iperf3 -c 10.10.0.12 -p 5201 »).
    func clientCommand(address: String?) -> String {
        let host = address ?? "<adresse de ce Mac>"
        let port = self.port ?? IperfProtocol.defaultPort
        return "iperf3 -c \(host)" + (port == IperfProtocol.defaultPort ? "" : " -p \(port)")
    }

    func start() {
        guard !isListening else { return }
        if let pending = stopping {
            // « Arrêter » puis « Démarrer » rapprochés : on attend que l'ancien serveur ait libéré le port.
            Task { [weak self] in
                await pending.value
                guard let self else { return }
                if self.stopping == pending { self.stopping = nil }
                self.start()
            }
            return
        }
        guard let port else {
            runState = .failed("Port invalide\u{00A0}: indiquez un nombre de 1 à 65\u{00A0}535.")
            return
        }
        notice = nil
        if demo {
            // Démonstration : rien n'écoute réellement.
            runState = .listening(port: port)
            scheduleAutoStop()
            return
        }
        // Chaque serveur a son jeton : les derniers événements d'un serveur arrêté (« Arrêter » puis
        // « Démarrer » rapprochés) sont ignorés au lieu d'être pris pour ceux du nouveau.
        let token = UUID()
        let server = IperfServer(configuration: IperfServerConfiguration(port: port)) { event in
            Task { @MainActor in IperfServerModel.shared.handle(event, from: token) }
        }
        do {
            let real = try server.start()
            self.server = server
            serverToken = token
            runState = .listening(port: real)
            scheduleAutoStop()
            ToolStore.shared.record(command: "iperf3 -s -p \(real)  (serveur intégré de NetScope)")
            AppLog.shared.info("iperf3", "Serveur iperf3 intégré à l’écoute sur le port \(real).")
        } catch {
            runState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Arrêt (bouton, délai écoulé, fermeture de l'app).
    func stop(automatic: Bool = false) {
        // L'arrêt attend jusqu'à 1 s la fin de l'écoute : hors du fil principal.
        if let old = server {
            let pending = Task.detached(priority: .userInitiated) { old.stop() }
            stopping = pending
            Task { [weak self] in
                await pending.value
                if self?.stopping == pending { self?.stopping = nil }
            }
        }
        server = nil
        serverToken = nil
        timer?.cancel()
        timer = nil
        stopAt = nil
        current = nil
        runState = .stopped
        if automatic {
            notice = "Serveur arrêté automatiquement après \(autoStopMinutes)\u{00A0}min sans test."
            AppLog.shared.info("iperf3", "Serveur iperf3 intégré arrêté automatiquement.")
        }
    }

    private func scheduleAutoStop() {
        stopAt = Date().addingTimeInterval(Double(autoStopMinutes) * 60)
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isListening, let stopAt = self.stopAt else { return }
                // Jamais pendant un test : l'arrêt attend sa fin.
                if Date() >= stopAt, self.current == nil {
                    self.stop(automatic: true)
                    return
                }
            }
        }
    }

    private func handle(_ event: IperfServerEvent, from token: UUID) {
        guard isListening, token == serverToken else { return }
        switch event {
        case .testStarted(let test):
            current = test
            notice = nil
        case .interval(let id, let interval):
            if current?.id == id { current?.intervals.append(interval) }
        case .testFinished(let test):
            current = nil
            add(test)
            ToolStore.shared.record(ToolRecent(tool: .iperf, target: test.client,
                                               summary: "Serveur intégré · \(SpeedFormat.rate(test.megabitsPerSecond)) Mb/s · \(test.directionLabel)",
                                               status: .ok))
            stopAt = Date().addingTimeInterval(Double(autoStopMinutes) * 60)
        case .testFailed(let client, let message):
            current = nil
            notice = "Test de \(client) interrompu\u{00A0}: \(message)"
            stopAt = Date().addingTimeInterval(Double(autoStopMinutes) * 60)
        case .refused(let client, let reason):
            notice = "Connexion de \(client) refusée\u{00A0}: \(reason)."
        }
    }

    func add(_ test: IperfServerTest) {
        tests = Array(([test] + tests).prefix(Self.keptTests))
    }

    // MARK: Démonstration

    func loadDemo(listening port: UInt16?, current: IperfServerTest?, tests: [IperfServerTest], stopIn minutes: Double?) {
        runState = port.map { .listening(port: $0) } ?? .stopped
        self.current = current
        self.tests = tests
        stopAt = minutes.map { Date().addingTimeInterval($0 * 60) }
    }
}
