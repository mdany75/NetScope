import NetScopeCore
import SwiftUI

// Note 73 : vues des actions sur un port — section du détail du port (Switchs et ports), rangée
// de la fiche Appareil, état de l'action en cours, feuille de confirmation et sa présentation.

/// Section « Actions sur le port » du détail d'un port.
struct PortActionsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = PortActionModel.shared
    @ObservedObject private var fortiGate = FortiGateStore.shared
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let target = model.target(snapshot: snapshot, iface: iface, state: state)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SwitchFieldLabel("Actions sur le port")
                Spacer(minLength: 8)
                if model.settings.enabled {
                    Chip(text: "Modifie le switch", tone: .warning, systemImage: "exclamationmark.triangle")
                }
            }
            if model.settings.enabled {
                PortActionButtons(target: target)
            } else {
                PortActionsDisabledNotice()
            }
            PortActionStatus(target: target)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        // Trousseau lu seulement une fois les actions autorisées (aucune demande d'accès sinon).
        .task(id: model.settings.enabled) {
            guard model.settings.enabled else { return }
            await model.checkCredentials()
            await fortiGate.loadTokens()
        }
    }
}

/// « Désactivées · Réglages… » (réglage d'origine).
struct PortActionsDisabledNotice: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                text
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 6) {
                text
                button
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
    }

    private var text: some View {
        Text("Cycle PoE et redémarrage du port désactivés (réglage d’origine).")
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        Button("Réglages…") {
            RegNavigation.shared.section = .switchs
            RegNavigation.shared.focus = .portActions
            state.open(.reglages)
        }
        .buttonStyle(.secondary)
        .controlSize(.small)
    }
}

/// Boutons des actions permises (grisés avec leur raison sinon).
struct PortActionButtons: View {
    @ObservedObject private var model = PortActionModel.shared
    let target: PortActionTarget

    var body: some View {
        let decisions = model.kinds(for: target).map { model.decision($0, target: target) }
        VStack(alignment: .leading, spacing: 6) {
            SwitchFlowLayout(spacing: 8) {
                ForEach(decisions, id: \.kind) { decision in
                    Button { model.ask(decision.kind, target: target) } label: {
                        Label(decision.kind.label, systemImage: decision.kind.symbol)
                    }
                    .buttonStyle(.secondary)
                    .disabled(!decision.isAllowed)
                    .help(decision.reason ?? helpText(decision))
                }
            }
            // Raisons visibles (une aide au survol ne se voit pas toujours) : chacune une fois.
            let reasons = decisions.flatMap(\.refusals).filter { $0 != .disabled && $0 != .busy }
            ForEach(Array(unique(reasons).prefix(2).enumerated()), id: \.offset) { _, refusal in
                Label(refusal.message, systemImage: refusal.isRiskyPort ? "hand.raised" : "info.circle")
                    .font(Theme.small)
                    .foregroundStyle(refusal.isRiskyPort ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func helpText(_ decision: PortActionDecision) -> String {
        "\(decision.kind.label) sur \(target.portLabel) par \(decision.channel?.label ?? "—") (confirmation demandée)"
    }

    private func unique(_ list: [PortActionRefusal]) -> [PortActionRefusal] {
        var seen: [PortActionRefusal] = []
        for item in list where !seen.contains(item) { seen.append(item) }
        return seen
    }
}

/// État de l'action en cours ou de la dernière action sur ce port.
struct PortActionStatus: View {
    @ObservedObject private var model = PortActionModel.shared
    let target: PortActionTarget

    var body: some View {
        if let run = model.run(for: target) {
            HStack(alignment: .top, spacing: 8) {
                if run.isRunning {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.kind.shortLabel + " en cours").font(Theme.bodySemibold)
                        Text(run.phase.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                } else if let record = run.record {
                    let tone = tone(record)
                    Image(systemName: record.success ? (tone == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "xmark.octagon.fill")
                        .foregroundStyle(tone.foreground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(record)).font(Theme.bodySemibold).foregroundStyle(tone == .success ? Theme.text : tone.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail(record)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button { model.clearResult(target) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Effacer ce résultat")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(background(run)))
        }
    }

    private func tone(_ record: PortActionRecord) -> Tone {
        if !record.success { return .critical }
        return record.returned?.isProblem == true ? .warning : .success
    }

    private func background(_ run: PortActionModel.Run) -> Color {
        guard let record = run.record else { return Theme.panelMuted }
        let tone = tone(record)
        return tone == .success ? Theme.successSoft : tone.background
    }

    private func title(_ record: PortActionRecord) -> String {
        guard record.success else { return "\(record.kind.shortLabel) échoué" }
        guard let returned = record.returned else { return "\(record.kind.shortLabel) effectué" }
        switch returned {
        case .returned: return "\(record.kind.shortLabel) effectué · \(record.deviceName ?? "appareil") \(returned.label)"
        default: return "\(record.kind.shortLabel) effectué · \(returned.label)"
        }
    }

    private func detail(_ record: PortActionRecord) -> String {
        var parts: [String] = []
        if !record.success, let message = record.errorMessage { parts.append(message) }
        parts.append("\(SwitchText.ago(record.date)) · par \(record.channel)")
        if record.simulated { parts.append("démonstration, rien n’a été envoyé") }
        return parts.joined(separator: " · ")
    }
}

/// Fiche Appareil : actions sur le port où l'appareil est branché (si le réglage les autorise et
/// que le port est relevé).
struct PortActionDeviceRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = PortActionModel.shared
    @ObservedObject private var switches = SwitchStore.shared
    @ObservedObject private var fortiGate = FortiGateStore.shared
    let device: Device

    var body: some View {
        if model.settings.enabled, let found = model.target(for: device, state: state) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ACTIONS SUR LE PORT").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                PortActionButtons(target: found.target)
                PortActionStatus(target: found.target)
            }
            .padding(.top, 4)
            .task {
                await model.checkCredentials()
                await fortiGate.loadTokens()
            }
        }
    }
}

// MARK: - Feuille de confirmation

/// Confirmation obligatoire : nomme le switch, le port, l'appareil branché et son IP, le moyen
/// d'envoi et le déroulement ; uplink ou port de ce Mac (permis par le réglage) : case à cocher.
/// Échap annule ; aucune touche ne lance l'action (clic sur le bouton rouge seulement).
struct PortActionSheet: View {
    @ObservedObject private var model = PortActionModel.shared
    let request: PortActionModel.Request
    var inline = false
    let dismiss: () -> Void

    @State private var acknowledged = false
    @State private var offSeconds = PortActionSettings.defaultOffSeconds
    @State private var loaded = false

    private var target: PortActionTarget { request.target }
    private var isSNMPCycle: Bool {
        if request.kind == .poeCycle, case .snmp? = request.decision.channel { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                facts
                if !request.decision.warnings.isEmpty { riskBox }
                RegNotice(consequence, tone: .warning)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            offSeconds = model.settings.poeOffSeconds
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft)
                Image(systemName: request.kind.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.warning)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.kind == .poeCycle ? "Couper et rallumer le PoE du port\u{00A0}?" : "Redémarrer le port\u{00A0}?")
                    .font(Theme.panelTitle).foregroundStyle(Theme.text)
                Text("NetScope va modifier l’état du switch\u{00A0}: action notée au journal et dans la chronologie de l’appareil.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            row("Switch", target.switchName + (target.usableSNMPHost.map { " (\($0))" } ?? (target.fortiGate.map { " · FortiSwitch, série \($0.serial.isEmpty ? $0.mkey : $0.serial)" } ?? "")))
            row("Port", target.portName + (target.isUplink ? " · uplink" : "") + (target.isThisMacPort ? " · port de ce Mac" : ""),
                color: target.isUplink || target.isThisMacPort ? Theme.critical : Theme.text)
            row("Appareil branché", (target.deviceName ?? "Inconnu") + (target.macCount > 1 ? " (+\(target.macCount - 1) autre\(target.macCount > 2 ? "s" : ""))" : ""), mono: false)
            row("Adresse IP", target.deviceIP?.description ?? "Inconnue · le retour ne pourra pas être suivi par ping")
            if let poe = target.poe { row("PoE actuel", poe.summary, mono: false) }
            row("Moyen", request.decision.channel?.label ?? "—", mono: false)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Déroulement").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(steps).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if isSNMPCycle {
                        Stepper(value: $offSeconds, in: PortActionSettings.offRange) {
                            Text("Coupure de \(offSeconds)\u{00A0}s").font(Theme.small).monospacedDigit()
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var steps: String {
        let follow = "puis ping de l’appareil jusqu’à son retour (\(PortActionFormat.seconds(model.settings.followUpSeconds)) au plus)."
        switch (request.kind, request.decision.channel) {
        case (.poeCycle, .snmp?):
            return "pethPsePortAdminEnable à false, attente, remise à true (trois essais au besoin), relevé du lien, " + follow
        case (.poeCycle, _):
            return "La FortiGate coupe puis rétablit elle-même le PoE du port (poe-reset), " + follow
        case (.portRestart, _):
            return "La FortiGate coupe le lien du port \(model.settings.bounceSeconds)\u{00A0}s puis le rétablit (bounce-port), " + follow
        }
    }

    private var consequence: String {
        switch request.kind {
        case .poeCycle:
            return "L’appareil branché perd son alimentation et redémarre\u{00A0}: une borne déconnecte ses clients Wi-Fi, un téléphone coupe l’appel en cours, une caméra cesse d’enregistrer pendant son démarrage."
        case .portRestart:
            return "Le lien du port tombe quelques secondes\u{00A0}: l’appareil perd le réseau et refait sa demande DHCP\u{00A0}; il n’est pas éteint."
        }
    }

    private var riskBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(request.decision.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.octagon.fill")
                    .font(Theme.small).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $acknowledged) {
                Text("Je comprends le risque et veux agir quand même sur ce port.").font(Theme.small)
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.criticalSoft))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(target.portLabel).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 8)
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(request.kind == .poeCycle ? "Couper et rallumer" : "Redémarrer le port") {
                model.perform(request, acknowledged: acknowledged, offSeconds: offSeconds)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.critical))
            .disabled(!request.decision.isAllowed || (!request.decision.warnings.isEmpty && !acknowledged))
            .help("Envoie l’action au switch (aucun raccourci clavier\u{00A0}: clic seulement)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func row(_ key: String, _ value: String, mono: Bool = true, color: Color = Theme.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Présentation

extension View {
    /// Note 73 : feuille de confirmation des actions sur un port (tous les écrans).
    func portActionPrompt() -> some View {
        modifier(PortActionPresenter())
    }
}

private struct PortActionPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = PortActionModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { snapshotSheet }
            .sheet(item: $model.request) { request in
                PortActionSheet(request: request, dismiss: { model.request = nil })
            }
    }

    /// Captures (NETSCOPE_PORT_FEUILLE) : la feuille dessinée par-dessus l'écran, comme une feuille
    /// de macOS (une vraie feuille ne se capture pas hors écran).
    @ViewBuilder private var snapshotSheet: some View {
        if [.switchs, .appareil].contains(state.screen), let request = PortActionDemo.snapshotRequest(state: state) {
            ZStack(alignment: .top) {
                Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                PortActionSheet(request: request, inline: true, dismiss: {})
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
            }
        }
    }
}
