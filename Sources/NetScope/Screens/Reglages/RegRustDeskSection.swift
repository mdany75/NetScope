import NetScopeCore
import SwiftUI

/// Réglages › RustDesk (note 6) : serveur auto-hébergé (hbbs, hbbr, clé publique), page
/// d'assistance de l'usager, nom du client portable, vérification du client de ce Mac, test du
/// serveur (sur clic seulement) et VIP de la FortiGate (lecture seule).
struct RegRustDeskSection: View {
    @ObservedObject private var rustdesk = RustDeskModel.shared
    @State private var portableName = ""
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Captures : NETSCOPE_RUSTDESK_VIEW=test montre d'abord le test du serveur et les VIP.
            if ProcessInfo.processInfo.environment["NETSCOPE_RUSTDESK_VIEW"] == "test" {
                testPanel
                clientPanel
            } else {
                serverPanel
                portablePanel
                clientPanel
                testPanel
            }
        }
        .onAppear { rustdesk.refreshInstalled() }
    }

    private func binding(_ path: WritableKeyPath<RustDeskServerSettings, String>) -> Binding<String> {
        Binding(get: { rustdesk.settings[keyPath: path] }, set: { rustdesk.settings[keyPath: path] = $0 })
    }

    // MARK: Serveur

    private var serverPanel: some View {
        RegPanel(title: "Serveur RustDesk",
                 subtitle: "Serveur auto-hébergé (RustDesk Server OSS\u{00A0}: hbbs et hbbr). Ces valeurs servent au client portable de l’usager et à la vérification du client de ce Mac. La clé publique n’est pas un secret.",
                 accessory: {
                     RegPill(text: rustdesk.settings.isConfigured ? "Configuré" : "À configurer",
                             tone: rustdesk.settings.isConfigured ? .success : .neutral)
                 }, content: {
                     VStack(alignment: .leading, spacing: 12) {
                         LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                             RegField(label: "Serveur d’ID (hbbs)") {
                                 RegTextField(placeholder: "assistance.exemple.ca", text: binding(\.idServer), mono: true)
                             }
                             RegField(label: "Serveur relais (hbbr, facultatif)") {
                                 RegTextField(placeholder: "Vide\u{00A0}: même hôte, port 21117", text: binding(\.relayServer), mono: true)
                             }
                             RegField(label: "Page d’assistance de l’usager") {
                                 RegTextField(placeholder: "https://assistance.exemple.ca/rustdesk", text: binding(\.supportPageURL), mono: true)
                             }
                             RegField(label: "Adresse interne du serveur (facultatif)") {
                                 RegTextField(placeholder: "192.168.10.20 · pour vérifier les VIP", text: binding(\.internalAddress), mono: true)
                             }
                         }
                         RegField(label: "Clé publique (id_ed25519.pub)") {
                             RegTextField(placeholder: "44 caractères base64, finit par «\u{00A0}=\u{00A0}»", text: binding(\.publicKey), mono: true,
                                          invalid: !rustdesk.settings.publicKey.isEmpty && RustDeskKey.problem(rustdesk.settings.publicKey) != nil)
                         }
                         ForEach(rustdesk.settings.issues(), id: \.self) { issue in
                             RegNotice(issue, tone: .critical)
                         }
                         VStack(alignment: .leading, spacing: 6) {
                             RegLabel("Importer depuis le nom du client portable")
                             HStack(spacing: 8) {
                                 RegTextField(placeholder: "rustdesk-host=assistance.exemple.ca,key=…,.exe", text: $portableName, mono: true)
                                     .onSubmit(importName)
                                 Button("Importer", action: importName)
                                     .buttonStyle(.secondary)
                                     .disabled(portableName.trimmingCharacters(in: .whitespaces).isEmpty)
                                     .help("Remplit le serveur d’ID, la clé, le relais et l’API à partir du nom du fichier .exe (host=, key=, relay=, api=)")
                             }
                             if let notice = rustdesk.notice {
                                 RegNotice(notice.text, tone: notice.tone)
                             }
                         }
                         .padding(.top, 4)
                         // Avis effacé dès qu'on saisit un autre nom, et en quittant la section.
                         .onChange(of: portableName) { _, value in
                             if !value.isEmpty { rustdesk.notice = nil }
                         }
                         .onDisappear { rustdesk.notice = nil }
                     }
                 })
    }

    private func importName() {
        if rustdesk.importPortable(portableName) { portableName = "" }
    }

    // MARK: Client portable

    private var portablePanel: some View {
        RegPanel(title: "Client portable de l’usager",
                 subtitle: "Le client Windows lit le serveur et la clé dans son propre nom de fichier\u{00A0}: rien à installer ni à régler chez l’usager. Publiez-le sous ce nom sur la page d’assistance.") {
            VStack(alignment: .leading, spacing: 10) {
                if let name = rustdesk.settings.portableClientFileName {
                    HStack(alignment: .center, spacing: 8) {
                        Text(name)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            rustdesk.copy(name)
                            flash("Nom copié")
                        } label: { Label("Copier le nom", systemImage: "doc.on.doc") }
                            .buttonStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                    if let problem = rustdesk.settings.portableNameProblem {
                        RegNotice(problem, tone: .warning)
                    }
                } else {
                    RegNotice("Remplissez le serveur d’ID et la clé publique pour obtenir le nom du client portable.", tone: .neutral)
                }
                HStack(spacing: 8) {
                    Button {
                        if let message = rustdesk.supportMessage {
                            rustdesk.copy(message)
                            flash("Message pour l’usager copié")
                        }
                    } label: { Label("Copier le lien d’assistance pour l’usager", systemImage: "link") }
                        .buttonStyle(.secondary)
                        .regDisabled(rustdesk.supportMessage == nil)
                        .help("Lien de la page d’assistance et consignes (ID, mot de passe à usage unique), prêts à coller dans un courriel")
                    if let copied {
                        Label(copied, systemImage: "checkmark").font(Theme.small).foregroundStyle(Theme.success)
                    }
                }
                Text("En portable, RustDesk ne tourne pas en service\u{00A0}: une fenêtre d’administration (UAC) demande «\u{00A0}Demander l’élévation\u{00A0}» dans la session. Pour un poste suivi régulièrement, installez RustDesk en service.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Client de ce Mac

    private var clientPanel: some View {
        RegPanel(title: "Client RustDesk de ce Mac",
                 subtitle: "Lecture seule de ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml\u{00A0}: serveur d’ID, relais et clé du client de bureau.",
                 accessory: {
                     // Petite fenêtre : libellé court plutôt qu'un bouton tronqué (le titre nomme déjà ce Mac).
                     ViewThatFits(in: .horizontal) {
                         clientCheckButton("Vérifier le client RustDesk de ce Mac")
                         clientCheckButton("Vérifier le client")
                     }
                 }, content: {
                     VStack(alignment: .leading, spacing: 8) {
                         HStack(spacing: 8) {
                             RegPill(text: rustdesk.isInstalled ? "RustDesk installé" : "RustDesk absent", tone: rustdesk.isInstalled ? .success : .warning)
                             if !rustdesk.isInstalled {
                                 Button("Télécharger RustDesk") { rustdesk.openDownloadPage() }
                                     .buttonStyle(.ghost)
                                     .help(RustDeskLink.downloadURL.absoluteString)
                             }
                             Spacer()
                             if let date = rustdesk.clientCheckedAt {
                                 Text("Vérifié \(RegFormat.moment(date))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                             }
                         }
                         if let findings = rustdesk.clientFindings {
                             RustDeskFindingList(findings: findings)
                         } else {
                             Text("Le client de bureau doit utiliser le même serveur d’ID et la même clé que les postes des usagers, sinon leurs ID sont introuvables.")
                                 .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                 .fixedSize(horizontal: false, vertical: true)
                         }
                     }
                 })
    }

    // MARK: Test du serveur

    private var testPanel: some View {
        RegPanel(title: "Tester le serveur",
                 subtitle: "Seulement sur clic\u{00A0}: connexion TCP aux ports 21115, 21116 et 21117 avec le temps de réponse, échange du protocole RustDesk sur 21115 (test NAT) et sur UDP 21116.",
                 accessory: {
                     // Petite fenêtre : boutons l'un sous l'autre plutôt que tronqués.
                     ViewThatFits(in: .horizontal) {
                         HStack(spacing: 8) { testButtons }.fixedSize()
                         VStack(alignment: .trailing, spacing: 6) { testButtons }.fixedSize()
                     }
                 }, content: {
                     VStack(alignment: .leading, spacing: 10) {
                         if rustdesk.testing {
                             HStack(spacing: 8) {
                                 ProgressView().controlSize(.small)
                                 Text("Test en cours…").font(Theme.small).foregroundStyle(Theme.textSecondary)
                             }
                         } else if rustdesk.probes.isEmpty {
                             RegNotice(rustdesk.settings.idEndpoint == nil ? "Indiquez d’abord le serveur d’ID." : "Aucun test lancé pour l’instant.", tone: .neutral)
                         } else {
                             VStack(spacing: 0) {
                                 ForEach(rustdesk.probes) { probe in probeRow(probe) }
                             }
                             .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                             .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                             .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
                             if let date = rustdesk.testedAt {
                                 Text("Testé \(RegFormat.moment(date)) depuis ce Mac. Depuis le réseau interne, un échec peut venir de la FortiGate qui ne fait pas le retour NAT (hairpin)\u{00A0}: refaire le test depuis l’extérieur au besoin.")
                                     .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                     .fixedSize(horizontal: false, vertical: true)
                             }
                         }
                         if rustdesk.checkingVIPs {
                             HStack(spacing: 8) {
                                 ProgressView().controlSize(.small)
                                 Text("Lecture des VIP…").font(Theme.small).foregroundStyle(Theme.textSecondary)
                             }
                         }
                         ForEach(rustdesk.vipReports) { report in
                             VStack(alignment: .leading, spacing: 6) {
                                 RegLabel("VIP de la FortiGate · \(report.site)")
                                 if let error = report.error {
                                     RegNotice(error, tone: .warning)
                                 } else {
                                     RustDeskFindingList(findings: report.findings)
                                 }
                             }
                             .padding(.top, 4)
                         }
                     }
                 })
    }

    private func clientCheckButton(_ title: String) -> some View {
        Button {
            rustdesk.checkClient()
        } label: { Label(title, systemImage: "checkmark.shield") }
            .buttonStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder private var testButtons: some View {
        if rustdesk.hasFortiGate {
            Button {
                rustdesk.checkVIPs()
            } label: { Label("Vérifier les VIP", systemImage: "shield.lefthalf.filled") }
                .buttonStyle(.secondary)
                .disabled(rustdesk.checkingVIPs)
                .help("Lit les VIP de chaque FortiGate (GET /api/v2/cmdb/firewall/vip, aucune écriture)")
        }
        Button {
            rustdesk.testServer()
        } label: { Label("Tester le serveur", systemImage: "bolt.horizontal") }
            .buttonStyle(.primary)
            .disabled(rustdesk.testing || rustdesk.settings.idEndpoint == nil)
    }

    private func probeRow(_ probe: RustDeskProbe) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RustDeskLevelIcon(level: probe.level)
            Text(probe.portLabel).font(Theme.mono(12, weight: .semibold)).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(probe.summary).font(Theme.small).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(probe.role) · \(probe.endpoint.label)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            Text(probe.millis.map { "\($0)\u{00A0}ms" } ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copied == text { copied = nil }
        }
    }
}

/// Liste de constats (client de ce Mac, VIP) : icône, titre et marche à suivre.
struct RustDeskFindingList: View {
    let findings: [RustDeskFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RustDeskLevelIcon(level: finding.level)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !finding.detail.isEmpty {
                            Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

struct RustDeskLevelIcon: View {
    let level: RustDeskFinding.Level

    var body: some View {
        switch level {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.critical)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(Theme.textSecondary)
        }
    }
}
