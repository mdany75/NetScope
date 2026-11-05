import NetScopeCore
import SwiftUI

/// Réglages › Alertes : alertes envoyées hors du Mac, par courriel (SMTP), par webhook
/// (Microsoft Teams, Slack, JSON générique) et sur téléphone (ntfy, Pushover, note 76). Interrupteur général désactivé par défaut : rien ne
/// part tant qu'il ne l'est pas, sauf un message d'essai demandé et confirmé. Les secrets vont
/// au Trousseau (service com.danymenard.netscope.alertes).
struct RegAlertsSection: View {
    @ObservedObject private var alerts = AlertDispatcher.shared

    /// Captures de développement : NETSCOPE_ALERTES_PARTIE=regles commence aux règles et au journal,
    /// =webhooks aux webhooks, =telephone aux canaux ntfy et Pushover (parties sous le pli de la
    /// fenêtre de capture).
    private static var capturePart: String? {
        AlertDispatcher.shared.isSandboxed ? ProcessInfo.processInfo.environment["NETSCOPE_ALERTES_PARTIE"] : nil
    }

    private var startsAtRules: Bool { Self.capturePart == "regles" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !startsAtRules && Self.capturePart != "telephone" { channelsPanel }
            if !startsAtRules { phonePanel }
            RegAlertRulesPanel()
            RegAlertJournalPanel()
        }
        .onAppear { alerts.refreshSecrets() }
    }

    private var channelsPanel: some View {
        RegPanel(title: "Alertes",
                 subtitle: "Prévenir hors du Mac, par courriel, dans Teams, Slack ou un autre service, ou sur le téléphone, quand une sonde tombe, qu’un serveur DHCP non autorisé répond ou qu’un service en ligne a un incident.",
                 accessory: { masterSwitch }) {
            statusBanner
            if Self.capturePart != "webhooks" {
                RegAlertMailCard()
                    .padding(.top, 14)
            }
            RegAlertWebhooksCard()
                .padding(.top, 14)
        }
    }

    /// Note 76 : notifications sur téléphone (ntfy, Pushover), côte à côte si la largeur le permet.
    private var phonePanel: some View {
        RegPanel(title: "Notifications sur téléphone",
                 subtitle: "Recevoir l’alerte loin du Mac, sans Teams\u{00A0}: ntfy (gratuit, auto-hébergeable) ou Pushover (licence unique par plateforme). Désactivés par défaut.",
                 accessory: { EmptyView() }) {
            RegColumns(minColumnWidth: 360) {
                RegAlertNtfyCard()
                RegAlertPushoverCard()
            }
        }
    }

    private var masterSwitch: some View {
        HStack(spacing: 8) {
            Text("Activer les alertes").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                .lineLimit(1)
            RegSwitch(isOn: $alerts.settings.isEnabled)
                .help(alerts.settings.isEnabled ? "Couper tous les envois hors du Mac" : "Autoriser les envois selon les règles ci-dessous")
        }
        .fixedSize()
    }

    @ViewBuilder private var statusBanner: some View {
        let channels = alerts.settings.enabledChannels
        let ready = channels.filter(alerts.isReady)
        if alerts.isSandboxed {
            RegNotice("Démonstration\u{00A0}: canaux fictifs, aucun courriel, webhook ni notification n’est envoyé.", tone: .neutral)
        } else if !alerts.settings.isEnabled {
            RegNotice("Alertes désactivées\u{00A0}: aucun courriel, webhook ni notification ne part. Réglez les canaux, essayez-les avec «\u{00A0}Envoyer un test\u{00A0}», puis activez les alertes.", tone: .neutral)
        } else if channels.isEmpty {
            RegNotice("Alertes activées, mais aucun canal n’est activé\u{00A0}: rien ne peut partir.", tone: .warning)
        } else if ready.count < channels.count {
            RegNotice("\(channels.count - ready.count) canal\(channels.count - ready.count > 1 ? "aux" : "") activé\(channels.count - ready.count > 1 ? "s" : "") incomplet\(channels.count - ready.count > 1 ? "s" : "")\u{00A0}: voir ci-dessous.", tone: .warning)
        } else {
            RegNotice("Alertes actives sur \(ready.count) canal\(ready.count > 1 ? "aux" : "")\u{00A0}: " + ready.map(alerts.settings.channelName).joined(separator: ", ") + ".", tone: .success)
        }
    }
}

// MARK: - Éléments communs

/// Encadré d'un canal (bordure fine, en-tête avec icône, titre, puce et interrupteur).
struct RegAlertBox<Header: View, Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accentStrong)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                header
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Puce de gravité (« CRITIQUE », « ALERTE », « INFO »), comme au croquis.
struct RegSeverityTag: View {
    let severity: AlertSeverity

    var tone: Tone {
        switch severity {
        case .critical: return .critical
        case .warning: return .warning
        case .info: return .accent
        }
    }

    var body: some View {
        Chip(text: severity.label.uppercased(), tone: tone)
    }
}

/// Résultat du dernier essai d'un canal (sous le bouton « Envoyer un test »).
struct RegAlertTestResult: View {
    let channel: AlertChannel
    @ObservedObject private var alerts = AlertDispatcher.shared

    var body: some View {
        if alerts.testing.contains(channel) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Envoi du message d’essai…").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        } else if let entry = alerts.lastTest[channel] {
            RegNotice(RegFormat.moment(entry.date) + " · " + (entry.outcome == .failed ? "" : entry.outcome.label + "\u{00A0}: ") + entry.detail,
                      tone: entry.outcome == .sent ? .success : entry.outcome == .failed ? .critical : .neutral)
        }
    }
}

/// Bouton « Envoyer un test » avec confirmation (rien ne part sans le second clic).
struct RegAlertTestButton: View {
    let channel: AlertChannel
    /// Destination décrite dans la confirmation (« dany@exemple.ca par smtp.exemple.ca »).
    let destination: String
    var compact = false
    @ObservedObject private var alerts = AlertDispatcher.shared
    @State private var confirm = false

    var body: some View {
        Button {
            confirm = true
        } label: {
            if compact {
                Label("Tester", systemImage: "paperplane")
            } else {
                Label("Envoyer un test", systemImage: "paperplane")
            }
        }
        .buttonStyle(.secondary)
        .fixedSize()
        .regDisabled(!alerts.isReady(channel) || alerts.testing.contains(channel))
        .help(alerts.isReady(channel) ? "Envoie un message d’essai sur ce canal (après confirmation)" : "Réglages du canal incomplets")
        .confirmationDialog("Envoyer un message d’essai\u{00A0}?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Envoyer le message d’essai") { alerts.sendTest(channel) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Un vrai message sera envoyé \(destination)." + (alerts.settings.isEnabled ? "" : " Les alertes restent désactivées\u{00A0}: seul cet essai part."))
        }
    }
}
