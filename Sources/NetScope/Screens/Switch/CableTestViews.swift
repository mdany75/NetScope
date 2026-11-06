import NetScopeCore
import SwiftUI

// Note 89 : vues du test de câble — section du détail du port (bouton, dernier résultat par
// paire, historique du port, indices sans test), feuille de confirmation et sa présentation.

/// Section « Test de câble (TDR) » du détail d'un port.
struct CableTestSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = CableTestModel.shared
    @ObservedObject private var actions = PortActionModel.shared
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let target = actions.target(snapshot: snapshot, iface: iface, state: state)
        let decision = model.decision(target, snapshot: snapshot)
        let history = model.history(switchName: target.switchName, port: target.portName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SwitchFieldLabel("Test de câble (TDR)")
                Spacer(minLength: 8)
                if model.isEnabled {
                    Chip(text: "Le lien peut tomber", tone: .warning, systemImage: "exclamationmark.triangle")
                }
            }
            if let hint { Label(hint, systemImage: "lightbulb").font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true) }
            if model.isEnabled {
                HStack(spacing: 8) {
                    Button { model.ask(snapshot: snapshot, iface: iface, state: state) } label: {
                        Label("Tester le câble…", systemImage: "cable.connector")
                    }
                    .buttonStyle(.secondary)
                    .disabled(!decision.isAllowed)
                    .help(decision.reason ?? "Demande au switch un test de câble par \(decision.channel?.label ?? "—") (confirmation demandée)")
                    if model.running.contains(CableTestModel.key(target)) {
                        ProgressView().controlSize(.small)
                        Text("Test en cours…").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let reason = decision.refusals.first(where: { $0 != .busy }) {
                    Label(reason.message, systemImage: reason.isRiskyPort ? "hand.raised" : "info.circle")
                        .font(Theme.small).foregroundStyle(reason.isRiskyPort ? Theme.warning : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Test de câble désactivé (réglage d’origine).").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button("Réglages…") {
                        RegNavigation.shared.section = .switchs
                        RegNavigation.shared.focus = .portActions
                        state.open(.reglages)
                    }
                    .buttonStyle(.secondary).controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            }
            if let last = history.first { CableTestResultView(result: last) }
            if history.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Historique du port").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    ForEach(history.dropFirst().prefix(4)) { item in
                        HStack(spacing: 6) {
                            Text(CableTestFormat.date(item.date)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            Text(item.headline).font(Theme.small).foregroundStyle(CableTestFormat.color(item.status)).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Indices déjà présents sans test : 100 Mb/s au lieu de 1 Gb/s, erreurs à l'entrée.
    private var hint: String? {
        guard iface.isUp else { return nil }
        var parts: [String] = []
        if iface.speedMbps == 100 { parts.append("lien négocié à 100\u{00A0}Mb/s (une paire abîmée empêche le 1\u{00A0}Gb/s)") }
        if let errors = iface.inErrors, errors > 0 { parts.append("\(errors) erreur\(errors > 1 ? "s" : "") à l’entrée (CRC)") }
        return parts.isEmpty ? nil : "Indice sans test\u{00A0}: " + parts.joined(separator: ", ") + "."
    }
}

/// Dernier résultat : titre et une puce par paire.
struct CableTestResultView: View {
    let result: CableTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.status == .ok ? "checkmark.circle.fill" : (result.status == .failure ? "xmark.octagon.fill" : "questionmark.circle"))
                    .foregroundStyle(CableTestFormat.color(result.status))
                Text(result.headline).font(Theme.bodyMedium).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            if !result.pairs.isEmpty {
                SwitchFlowLayout(spacing: 6) {
                    ForEach(result.pairs, id: \.pair) { pair in
                        Chip(text: pair.summary.prefix(1).uppercased() + pair.summary.dropFirst(),
                             tone: pair.status.isFault ? .critical : (pair.status == .ok ? .success : .neutral))
                    }
                }
            }
            Text("\(CableTestFormat.date(result.date)) · \(result.channel)").font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
    }
}

enum CableTestFormat {
    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    static func color(_ status: LinkCheckStatus) -> Color {
        switch status {
        case .ok: return Theme.success
        case .warning: return Theme.warning
        case .failure: return Theme.critical
        case .skipped: return Theme.textSecondary
        }
    }
}

/// Feuille de confirmation du test de câble.
struct CableTestSheet: View {
    @ObservedObject private var model = CableTestModel.shared
    let request: CableTestModel.Request
    let dismiss: () -> Void
    @State private var acknowledged = false

    private var target: PortActionTarget { request.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft)
                        Image(systemName: "cable.connector").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.warning)
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tester le câble").font(Theme.panelTitle)
                        Text("Le switch mesure chaque paire par réflectométrie (TDR).").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                }
                VStack(spacing: 0) {
                    row("Switch", target.switchName)
                    row("Port", target.portName)
                    row("Appareil branché", target.deviceLabel)
                    row("Envoyé par", request.decision.channel?.label ?? "—", mono: false)
                    row("Commande", commandText)
                }
                if !request.decision.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(request.decision.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.message, systemImage: "hand.raised").font(Theme.small).foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Je comprends, tester quand même", isOn: $acknowledged).toggleStyle(.checkbox)
                    }
                }
                RegNotice("Le lien du port peut tomber quelques secondes pendant le test\u{00A0}: l’appareil branché (\(target.deviceLabel)) sera brièvement déconnecté. Le résultat est gardé dans l’historique du port.",
                          tone: .warning)
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(target.portLabel).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Lancer le test") {
                    model.perform(request, acknowledged: acknowledged)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.critical))
                .disabled(!request.decision.isAllowed || (!request.decision.warnings.isEmpty && !acknowledged))
                .help("Envoie la demande de test au switch (clic seulement)")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(Theme.panel)
    }

    private var commandText: String {
        switch request.decision.channel {
        case .ssh(_, let vendor)?:
            let plan = CableTestCommands.plan(vendor: vendor, port: target.portName)
            return plan?.steps.flatMap { $0 }.first { $0.contains(target.portName) } ?? "—"
        case .fortiGate?: return "GET cable-status (port \(target.portName))"
        case nil: return "—"
        }
    }

    private func row(_ key: String, _ value: String, mono: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

extension View {
    /// Note 89 : feuille de confirmation du test de câble (dessinée par-dessus l'écran en capture).
    func cableTestPrompt() -> some View { modifier(CableTestPresenter()) }
}

private struct CableTestPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = CableTestModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { snapshotSheet }
            .sheet(item: $model.request) { request in
                CableTestSheet(request: request, dismiss: { model.request = nil })
            }
    }

    /// Captures (NETSCOPE_CABLE_FEUILLE=1) : la feuille sur le premier port actif d'un switch Cisco.
    @ViewBuilder private var snapshotSheet: some View {
        if CommandLine.arguments.contains("--snapshot"), state.screen == .switchs,
           ProcessInfo.processInfo.environment["NETSCOPE_CABLE_FEUILLE"] != nil,
           let snapshot = SwitchStore.shared.orderedSnapshots.first(where: { !$0.isViaController }),
           let iface = snapshot.physicalPorts.first(where: { $0.isUp && !snapshot.locatedUplinks.contains($0.index) }) {
            let target = PortActionModel.shared.target(snapshot: snapshot, iface: iface, state: state)
            let request = model.makeRequest(target: target, decision: model.decision(target, snapshot: snapshot), snapshot: snapshot)
            ZStack(alignment: .top) {
                Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                CableTestSheet(request: request, dismiss: {})
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
            }
        }
    }
}
