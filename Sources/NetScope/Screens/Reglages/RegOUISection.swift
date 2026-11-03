import NetScopeCore
import SwiftUI

/// Pilote la base des fabricants (OUI) : provenance, mise à jour depuis l'IEEE (sur demande de
/// l'utilisateur seulement), retour à la base fournie avec l'application.
@MainActor
final class OUIController: ObservableObject {
    static let shared = OUIController()

    enum Phase: Equatable {
        case idle
        case working(step: String, fraction: Double)
        case done(String)
        case failed(String)
    }

    @Published private(set) var source: OUIDatabase.Source?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasUserFile = false

    private var task: Task<Void, Never>?

    private init() {}

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Lit la provenance hors du fil principal (le premier accès charge la base).
    func refresh() {
        Task.detached(priority: .userInitiated) {
            let source = OUIDatabase.builtIn.source
            let hasUserFile = FileManager.default.fileExists(atPath: OUIDatabase.userFileURL.path)
            await MainActor.run {
                self.source = source
                self.hasUserFile = hasUserFile
            }
        }
    }

    func update(state: AppState?) {
        guard !RegEnvironment.isSandboxed else {
            phase = .failed("Mise à jour indisponible en mode démonstration.")
            return
        }
        guard task == nil else { return }
        phase = .working(step: "Connexion à standards-oui.ieee.org…", fraction: 0)
        task = Task { [weak self] in
            do {
                let source = try await OUIUpdater().update { progress in
                    Task { @MainActor in
                        guard let self, self.isWorking else { return }
                        self.phase = .working(step: progress.step, fraction: progress.fraction)
                    }
                }
                guard let self else { return }
                self.source = source
                self.hasUserFile = true
                self.phase = .done("Base mise à jour : \(source.description).")
                state?.objectWillChange.send()
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed("\(error)")
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func revert(state: AppState?) {
        guard !RegEnvironment.isSandboxed else {
            phase = .failed("Indisponible en mode démonstration.")
            return
        }
        do {
            let source = try OUIUpdater().revert()
            self.source = source
            hasUserFile = false
            phase = .done("Retour à la base intégrée : \(source.description).")
            state?.objectWillChange.send()
        } catch {
            phase = .failed("\(error)")
        }
    }
}

/// Réglages › Général › Base des fabricants.
struct RegOUISection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var controller = OUIController.shared

    var body: some View {
        RegPanel(title: "Base des fabricants",
                 subtitle: "Préfixes des adresses MAC (registre IEEE) : le scanner, l’inventaire et la fiche appareil y trouvent le fabricant.") {
            HStack(spacing: 10) {
                RegTile("Source", controller.source?.description ?? "Chargement…")
                RegTile("Préfixes", controller.source.map { "\($0.count.formatted(.number.locale(Locale(identifier: "fr_CA"))))" } ?? "—")
                RegTile("Emplacement", controller.source?.place ?? "—")
            }

            if case .working(let step, let fraction) = controller.phase {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                }
                .padding(.top, 12)
            }

            notice.padding(.top, 12)

            HStack(spacing: 8) {
                if controller.isWorking {
                    Button("Annuler") { controller.cancel() }.buttonStyle(.secondary)
                } else {
                    Button {
                        controller.update(state: state)
                    } label: { Label("Mettre à jour depuis l’IEEE", systemImage: "arrow.down.circle") }
                        .buttonStyle(.primary)
                        .disabled(RegEnvironment.isSandboxed)
                        .opacity(RegEnvironment.isSandboxed ? 0.5 : 1)
                    let canRevert = !RegEnvironment.isSandboxed && controller.hasUserFile
                    Button("Revenir à la base intégrée") { controller.revert(state: state) }
                        .buttonStyle(.secondary)
                        .disabled(!canRevert)
                        .opacity(canRevert ? 1 : 0.5)
                        .help(controller.hasUserFile ? "Supprime la base mise à jour et reprend celle fournie avec l’application."
                                                     : "Aucune base mise à jour : la base fournie avec l’application est déjà utilisée.")
                }
                Spacer()
            }
            .padding(.top, 12)
        }
        .onAppear { controller.refresh() }
    }

    @ViewBuilder private var notice: some View {
        switch controller.phase {
        case .done(let text):
            RegNotice(text, tone: .success)
        case .failed(let text):
            RegNotice(text, tone: .critical)
        default:
            if RegEnvironment.isSandboxed {
                RegNotice("Mode démonstration : la mise à jour depuis l’IEEE est désactivée.", tone: .neutral)
            } else {
                RegNotice("La mise à jour télécharge trois fichiers du registre IEEE (environ 5 Mo) depuis standards-oui.ieee.org, seulement quand vous cliquez. La base mise à jour est enregistrée dans ~/Library/Application Support/NetScope/oui.tsv.", tone: .neutral)
            }
        }
    }
}
