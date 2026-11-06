import AppKit
import NetScopeCore
import SwiftUI

// Note 24 : FortiSwitch gérés par la FortiGate dans l'écran Switchs et ports : bandeau du
// contrôleur. Note 83 : le tableau des ports d'un FortiSwitch est devenu le tableau commun de
// l'onglet Ports (SwitchPortsTab.swift), le même pour les switchs SNMP.

extension SwitchText {
    /// « 10.255.1.2 (FortiLink) », ou « adresse FortiLink inconnue » (adresse de remplacement 0.0.0.n).
    static func fortiLinkAddress(_ snapshot: SNMPSwitchSnapshot) -> String {
        if let real = snapshot.fortiLinkIP { return "\(real) (FortiLink)" }
        return snapshot.host.value < (1 << 24) ? "adresse FortiLink inconnue" : "\(snapshot.host) (FortiLink)"
    }

    /// Note 77 : adresse de gestion d'un switch lu par UniFi, Omada ou Meraki ; adresse FortiLink
    /// d'un FortiSwitch.
    static func controllerAddress(_ snapshot: SNMPSwitchSnapshot) -> String {
        guard snapshot.controllerKind != nil else { return fortiLinkAddress(snapshot) }
        return snapshot.host.value < (1 << 24) ? "adresse inconnue" : snapshot.host.description
    }

    /// Uptime pour un switch SNMP ; nom du contrôleur pour un FortiSwitch (FortiOS ne publie pas
    /// l'uptime des switchs dans les adresses lues).
    static func uptimeOrController(_ snapshot: SNMPSwitchSnapshot) -> String {
        if let controller = snapshot.controllerName { return controller }
        return snapshot.system.uptimeText ?? "—"
    }
}

/// Bandeau des FortiGate (notes 24 et 25) : « FortiGate utilisée : Siège (10.182.0.0/16) », la
/// liste quand plusieurs sites sont scannés, ou « Aucune FortiGate pour cette plage : SNMP
/// seulement » ; état de chaque lecture, relecture à la demande.
struct SwitchFortiGatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        if fortigate.isConfigured {
            let selection = currentSelection
            Panel(padding: 14) {
                AdaptiveStack(breakpoint: 900, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(SwitchSource.fortigate.colors.background)
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 15)).foregroundStyle(SwitchSource.fortigate.colors.foreground)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            headline(selection)
                                .font(Theme.bodySemibold)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !fortigate.isEnabled {
                                Text("Lecture des FortiGate désactivée dans Réglages › Switchs\u{00A0}: SNMP seulement.")
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            } else if selection.picks.count == 1, let pick = selection.picks.first {
                                pickDetail(pick)
                            } else if selection.picks.count > 1 {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(selection.picks) { pick in pickRow(pick) }
                                }
                                .padding(.top, 2)
                            } else {
                                Text(emptyDetail(selection))
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if fortigate.isEnabled, !selection.picks.isEmpty, !selection.uncovered.isEmpty {
                                // Plage scannée couverte en partie : le reste n'est vu qu'en SNMP.
                                Text("Sans FortiGate (SNMP seulement)\u{00A0}: " + selection.uncovered.prefix(3).joined(separator: ", ")
                                     + (selection.uncovered.count > 3 ? "…" : ""))
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if fortigate.conflicts.contains(where: \.isAmbiguous) {
                                Label("Conflit de plages entre FortiGate\u{00A0}: voir Réglages › Switchs › Contrôleurs FortiGate.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(Theme.small).foregroundStyle(Theme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button("Réglages…") {
                            RegNavigation.shared.section = .switchs
                            state.open(.reglages)
                        }
                        .buttonStyle(.secondary)
                        Button { fortigate.refreshNow(state: state) } label: {
                            HStack(spacing: 6) {
                                if fortigate.isBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                                }
                                Text(fortigate.isBusy ? "Lecture…" : (selection.picks.count > 1 ? "Relire les FortiGate" : "Relire la FortiGate"))
                            }
                        }
                        .buttonStyle(.secondary)
                        // « Relire » lit les plages cochées en ce moment : c'est leur choix qui compte, pas
                        // celui de la dernière lecture.
                        .disabled(fortigate.isBusy || !fortigate.isEnabled || fortigate.previewSelection(state: state).isEmpty
                                  || !(fortigate.isReady || fortigate.isDemo))
                        .help("Relit, par leur API REST (HTTPS, lecture seule), les FortiGate qui couvrent les plages cochées du Scanner (sinon l’adresse de ce Mac)\u{00A0}: FortiSwitch, ports et appareils détectés.")
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// Choix de la dernière lecture (pour le détail de chaque lecture) ; avant toute lecture, ou si
    /// elle n'a choisi aucune FortiGate, celui des plages cochées en ce moment.
    private var currentSelection: FortiControllerSelection {
        guard fortigate.lastRefresh != nil, !fortigate.selection.isEmpty else { return fortigate.previewSelection(state: state) }
        return fortigate.selection
    }

    private func headline(_ selection: FortiControllerSelection) -> Text {
        guard fortigate.isEnabled else { return Text("FortiGate\u{00A0}: lecture désactivée") }
        switch selection.picks.count {
        case 0:
            return Text("Aucune FortiGate pour cette plage\u{00A0}: SNMP seulement")
        case 1:
            let pick = selection.picks[0]
            return Text("FortiGate utilisée\u{00A0}: ") + Text(pick.site)
                + (pick.coveredRanges.isEmpty ? Text("") : Text(" (") + Text(pick.rangeLabel).font(Theme.mono(12.5, weight: .semibold)) + Text(")"))
        default:
            return Text("FortiGate utilisées\u{00A0}: \(selection.picks.count) sites")
        }
    }

    private func emptyDetail(_ selection: FortiControllerSelection) -> String {
        let ranges = selection.uncovered.prefix(3).joined(separator: ", ")
        let head = ranges.isEmpty ? "Ni les plages cochées ni l’adresse de ce Mac" : "\(ranges)\(selection.uncovered.count > 3 ? "…" : "")\u{00A0}:"
        return ranges.isEmpty
            ? "\(head) ne sont couvertes par une FortiGate de la liste. Ajoutez la plage au site concerné dans Réglages › Switchs."
            : "\(head) aucune FortiGate de la liste ne couvre ces adresses. Ajoutez la plage au site concerné dans Réglages › Switchs."
    }

    /// Détail d'une FortiGate choisie seule : sa lecture ou la raison de l'échec.
    private func pickDetail(_ pick: FortiControllerSelection.Pick) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusChip(pick.controllerID)
            detail(pick)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ligne d'une FortiGate parmi plusieurs.
    private func pickRow(_ pick: FortiControllerSelection.Pick) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusChip(pick.controllerID)
            (Text(pick.site).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text)
                + (pick.coveredRanges.isEmpty ? Text("") : Text(" (\(pick.rangeLabel))").font(Theme.mono(11.5)).foregroundStyle(Theme.text))
                + Text(" · ") + detail(pick))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ pick: FortiControllerSelection.Pick) -> Text {
        let id = pick.controllerID
        let why: String
        switch pick.reason {
        case .scannedRange: why = ""
        case .macAddress: why = "choisie par l’adresse de ce Mac · "
        case .noRanges: why = "plages couvertes à renseigner · "
        case .activeSite: why = "FortiGate du site actif · "
        }
        if fortigate.runtime[id]?.busy == true { return Text(why + "lecture en cours…") }
        if let site = fortigate.sites.first(where: { $0.controllerID == id }) {
            let report = site.report
            let devices = report.locatedDevices.count
            return Text(why) + Text(report.controllerName).font(Theme.mono(11.5)).foregroundStyle(Theme.text)
                + Text(" · \(report.system.model) · \(report.system.versionLabel) · \(report.switches.count) FortiSwitch · \(devices) appareil\(devices > 1 ? "s" : "") détecté\(devices > 1 ? "s" : "") · lu \(SwitchText.ago(report.readAt)) · prioritaire sur SNMP")
        }
        if let c = fortigate.controller(id), let reason = fortigate.notReadyReason(c) { return Text(why + reason) }
        if let error = fortigate.runtime[id]?.error { return Text(why + error) }
        return Text(why + "Les FortiSwitch seront lus à la fin du prochain scan, ou avec «\u{00A0}Relire\u{00A0}».")
    }

    @ViewBuilder private func statusChip(_ id: UUID) -> some View {
        let r = fortigate.runtime[id]
        if r?.busy == true {
            Chip(text: "Lecture…", tone: .accent)
        } else if fortigate.sites.contains(where: { $0.controllerID == id }) {
            Chip(text: "Lue", tone: .success)
        } else if let c = fortigate.controller(id), !fortigate.hasToken(id), !fortigate.isDemo || c.lastStatus?.kind == .missingToken {
            Chip(text: "Jeton manquant", tone: .warning)
        } else if r?.pending != nil || fortigate.controller(id).map({ fortigate.notReadyReason($0) != nil }) == true {
            Chip(text: "À configurer", tone: .warning)
        } else if r?.error != nil {
            Chip(text: "Erreur", tone: .critical)
        } else {
            Chip(text: "Pas encore lue", tone: .neutral)
        }
    }
}
