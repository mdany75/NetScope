import NetScopeCore
import SwiftUI

/// Écran « Ping continu » (docs/croquis/Ping.dc.html) : cibles en parallèle, grand graphe de la
/// cible choisie, MTR / traceroute et journal des événements. Le ping démarre à la première
/// ouverture de l'écran et continue ensuite en arrière-plan.
struct PingScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var controller = PingController.shared
    @State private var newTarget = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if let note = modeNote {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 13))
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.small)
                .foregroundStyle(Color(hex: 0x1E3A8A))
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xDBEAFE)).frame(height: 1) }
            }
            GeometryReader { geometry in
                ScrollView {
                    content(width: geometry.size.width - Theme.contentPadding * 2)
                        .padding(.horizontal, Theme.contentPadding)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .screenToolbar { toolbarActions }
        .onAppear { controller.activate(with: state) }
        .onChange(of: state.pingTargets) { _, inputs in controller.sync(with: inputs) }
    }

    // MARK: Barre d'outils

    @ViewBuilder private var toolbarActions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                StatusDot(tone: controller.isPaused || !controller.hasStarted ? .neutral : .success)
                Text(controller.isPaused ? "En pause" : controller.hasStarted ? "En direct" : "Arrêté")
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.text)
                Text(sessionInfo(now: context.date))
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        Button { controller.exportCSV() } label: {
            Label("Exporter CSV", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.secondary)
        .disabled(controller.totalSent == 0)
        .help("Enregistrer toutes les mesures (horodatage, cible, rtt_ms, perdu) en CSV")
    }

    private func sessionInfo(now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(controller.sessionStart)))
        let clock = String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
        return "Session \(clock) · \(controller.targets.count) cibles · \(controller.totalSent) envoyés · \(controller.totalLost) perdus"
    }

    // MARK: Barre de contrôle

    private var controlBar: some View {
        // Une ligne si la fenêtre est assez large, sinon deux (comme le croquis, qui passe à la ligne).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                addField.frame(width: 340)
                settingsGroup
                Spacer(minLength: 0)
                runButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    addField.frame(minWidth: 280, maxWidth: 560)
                    Spacer(minLength: 0)
                    runButtons
                }
                HStack(spacing: 14) {
                    settingsGroup
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("", text: $newTarget,
                          prompt: Text("Ajouter une cible (IP, hostname, plage)").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit(addTarget)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
            Button(action: addTarget) {
                Label("Ajouter", systemImage: "plus")
            }
            .buttonStyle(.primary)
            .fixedSize()
            .disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty
                      || controller.targets.count >= PingController.maxTargets)
        }
    }

    private var settingsGroup: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Intervalle").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Menu {
                    ForEach(PingOptions.intervals, id: \.self) { value in
                        Button(PingFormat.duration(value)) { controller.setInterval(value) }
                    }
                } label: {
                    Text(PingFormat.duration(controller.interval)).font(Theme.body)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: Theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
            }

            HStack(spacing: 6) {
                Text("Paquet").font(Theme.small).foregroundStyle(Theme.textSecondary)
                PingSegmented(options: [.init(value: 56, title: "56 o"),
                                        .init(value: 1472, title: "1472 o · MTU",
                                              help: "1472 octets + 28 d’en-têtes = 1500 octets, bit DF activé")],
                              selection: controller.payloadSize) { controller.setPayloadSize($0) }
            }

            HStack(spacing: 6) {
                Text("Mode").font(Theme.small).foregroundStyle(Theme.textSecondary)
                PingSegmented(options: [.init(value: "ICMP", title: "ICMP"),
                                        .init(value: "TCP", title: "TCP:443", enabled: false, help: "Bientôt : temps d’établissement TCP (SYN → SYN/ACK)"),
                                        .init(value: "ARP", title: "ARP", enabled: false, help: "Bientôt : sondage ARP du sous-réseau local")],
                              selection: "ICMP") { _ in }
            }

            Toggle(isOn: $controller.soundOnLoss) {
                Text("Son à la perte").font(Theme.body)
            }
            .toggleStyle(.checkbox)
        }
        .fixedSize()
    }

    private var runButtons: some View {
        HStack(spacing: 6) {
            if controller.isPaused {
                Button(action: controller.togglePause) { Label("Reprendre", systemImage: "play.fill") }
                    .buttonStyle(.primary)
            } else {
                Button(action: controller.togglePause) { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.secondary)
                    .disabled(!controller.hasStarted)
            }
            Button(action: controller.reset) { Label("Réinitialiser", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.secondary)
        }
        .fixedSize()
    }

    private func addTarget() {
        let text = newTarget.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        controller.addFromField(text)
        newTarget = ""
    }

    private var modeNote: String? {
        guard controller.payloadSize > 1000 else { return nil }
        if controller.dontFragmentRefused {
            return "Test MTU : le système a refusé le bit DF, les paquets de 1500 octets peuvent être fragmentés ; le résultat n’est pas fiable."
        }
        return "Test MTU : 1472 octets de données + 28 octets d’en-tête IP/ICMP = 1500 octets, bit DF activé. Une perte franche signale un MTU réduit sur le chemin (tunnel, PPPoE)."
    }

    // MARK: Contenu

    @ViewBuilder private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            targetsSection(width: width)
            if let target = controller.selectedTarget {
                let wide = width >= 1000
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            PingChartPanel(target: target, interval: controller.interval)
                            PingMTRPanel(controller: controller, target: target)
                        }
                        .frame(width: (width - 16) * 1.7 / 2.7)
                        PingJournalPanel(controller: controller)
                            .frame(width: (width - 16) / 2.7)
                    }
                } else {
                    PingChartPanel(target: target, interval: controller.interval)
                    PingMTRPanel(controller: controller, target: target)
                    PingJournalPanel(controller: controller)
                }
            } else {
                PingJournalPanel(controller: controller)
            }
        }
        .frame(width: max(0, width), alignment: .topLeading)
    }

    @ViewBuilder private func targetsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CIBLES · \(controller.targets.count)")
                    .font(Theme.captionSemibold)
                    .kerning(0.6)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Text("Cliquer sur une carte pour l’analyser · statistiques sur les \(PingController.cardWindow) dernières mesures (\(PingFormat.duration(Double(PingController.cardWindow) * controller.interval)))")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if controller.targets.isEmpty {
                Panel {
                    EmptyState(systemImage: "waveform.path.ecg",
                               title: controller.hasStarted ? "Aucune cible" : "Démarrage…",
                               message: "Ajoutez une adresse, un nom d’hôte ou une plage dans le champ ci-dessus, ou envoyez un appareil depuis le Scanner.")
                        .frame(height: 160)
                }
            } else {
                let columns = width >= 900 ? 3 : width >= 560 ? 2 : 1
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                          alignment: .leading, spacing: 12) {
                    ForEach(controller.targets) { target in
                        PingTargetCard(target: target,
                                       isSelected: target.id == controller.selectedTarget?.id,
                                       onSelect: { controller.selectedID = target.id },
                                       onRemove: { controller.remove(target.id) })
                    }
                }
            }
        }
    }
}
