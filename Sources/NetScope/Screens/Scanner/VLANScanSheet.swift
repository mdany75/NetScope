import NetScopeCore
import SwiftUI

/// Note 90 : feuille « Scanner un VLAN tagué » (Scanner et bilan de raccordement).
struct VLANScanSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = VLANScanModel.shared
    var inline = false
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                form
                let proposals = model.proposals()
                if !proposals.isEmpty { proposalRow(proposals) }
                RegNotice("macOS demande le mot de passe administrateur pour créer l’interface 802.1Q, puis pour la retirer. Elle est toujours retirée à la fin du scan, après une erreur, une annulation ou à la fermeture de NetScope. Le port du switch doit être en trunk et transporter ce VLAN.",
                          tone: .neutral)
                status
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 540)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scanner un VLAN tagué").font(Theme.panelTitle)
                Text("Interface temporaire sur l’Ethernet de ce Mac, sans changer de port.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                labeled("VLAN") {
                    TextField("20", text: $model.vlanText).textFieldStyle(.roundedBorder).frame(width: 80)
                        .font(Theme.mono(12))
                }
                labeled("Ethernet") {
                    Picker("", selection: $model.parent) {
                        ForEach(model.ethernetChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                Spacer(minLength: 0)
            }
            Picker("", selection: $model.useDHCP) {
                Text("Adresse par DHCP").tag(true)
                Text("IP fixe").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            if !model.useDHCP {
                HStack(spacing: 12) {
                    labeled("Adresse") { TextField("10.0.20.250", text: $model.fixedAddress).textFieldStyle(.roundedBorder).frame(width: 130) }
                    labeled("Préfixe") {
                        Stepper(value: $model.fixedPrefix, in: 8...30) { Text("/\(model.fixedPrefix)").font(Theme.mono(12)) }.fixedSize()
                    }
                    labeled("Passerelle") { TextField("10.0.20.1", text: $model.fixedRouter).textFieldStyle(.roundedBorder).frame(width: 130) }
                }
            }
            if case .failure(let error) = model.validatedRequest(), !model.vlanText.isEmpty {
                Label(error.message, systemImage: "info.circle").font(Theme.small).foregroundStyle(Theme.warning)
            }
        }
        .disabled(model.phase.isRunning)
    }

    private func proposalRow(_ proposals: [VLANProposal]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VLAN vus sur le réseau").font(Theme.small).foregroundStyle(Theme.textSecondary)
            SwitchFlowLayout(spacing: 6) {
                ForEach(proposals) { proposal in
                    Button { model.vlanText = String(proposal.vlan) } label: {
                        Text("VLAN \(proposal.vlan)").font(Theme.mono(11, weight: .semibold))
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .help("Vu par\u{00A0}: \(proposal.sources.joined(separator: ", "))")
                }
            }
        }
        .disabled(model.phase.isRunning)
    }

    @ViewBuilder private var status: some View {
        if model.phase != .idle {
            HStack(spacing: 8) {
                if model.phase.isRunning { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phase.label).font(Theme.small.weight(.medium)).foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                    if let obtained = model.obtained {
                        Text(obtained).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        }
    }

    private var tone: Color {
        switch model.phase {
        case .failed: return Theme.critical
        case .finished: return Theme.success
        default: return Theme.text
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.isDemo ? "Démonstration\u{00A0}: rien n’est créé ni scanné." : "Interface\u{00A0}: NetScope-VLAN-<numéro>")
                .font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 8)
            if model.phase.isRunning {
                Button("Annuler le scan") { model.cancel() }.buttonStyle(.secondary)
            } else {
                Button("Fermer", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Créer et scanner") { model.start(state) }
                    .buttonStyle(.primary)
                    .disabled({ if case .success = model.validatedRequest() { return false } else { return true } }())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

extension View {
    /// Note 90 : feuille du scan d'un VLAN tagué (dessinée par-dessus l'écran pendant les captures).
    func vlanScanPrompt() -> some View { modifier(VLANScanPresenter()) }
}

private struct VLANScanPresenter: ViewModifier {
    @ObservedObject private var model = VLANScanModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if CommandLine.arguments.contains("--snapshot"), ProcessInfo.processInfo.environment["NETSCOPE_VLAN_FEUILLE"] != nil {
                    ZStack(alignment: .top) {
                        Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                        VLANScanSheet(inline: true, dismiss: {})
                            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                            .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                            .padding(.top, 8)
                    }
                }
            }
            .sheet(isPresented: $model.isPresented) {
                VLANScanSheet(dismiss: { model.isPresented = false })
            }
    }
}
