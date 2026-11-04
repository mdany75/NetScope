import NetScopeCore
import SwiftUI

// « Suis-je sur un port PoE ? » (note 12) : réponses communes à la capture LLDP/CDP, à l'encart
// « Ce Mac est branché sur… », au Scanner et à la fiche Appareil.

/// Réponse pour ce Mac, d'après l'annonce LLDP/CDP du switch : deux réponses nettes (port PoE,
/// courant fourni) puis le détail (type, classe, puissance demandée et allouée).
struct PoEMacAnswer: View {
    let power: PoEPowerInfo?
    /// Résumé d'une capture antérieure au détail PoE (seul le texte avait été gardé).
    var legacySummary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                Text("Suis-je sur un port PoE\u{00A0}?").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let power {
                    Text(power.sources.map(\.rawValue).joined(separator: " + "))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            AdaptiveAnswers(items: [
                ("Port PoE", PoEPowerInfo.answer(power?.isPoEPort), power?.isPoEPort),
                ("Alimentation fournie", PoEPowerInfo.answer(power?.isPowerDelivered), power?.isPowerDelivered),
            ])
            NeighborFieldGrid(rows: rows, minColumnWidth: 220)
            Text(note)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var rows: [(String, String)] {
        guard let power else {
            return [("Type", "—"), ("Classe", "—"), ("Puissance demandée", "—"), ("Puissance allouée", "—")]
        }
        var rows: [(String, String)] = [
            ("Type", power.typeLabel ?? "—"),
            ("Classe", power.powerClass.map(String.init) ?? "—"),
            ("Puissance demandée", power.requestedW.map(PoEPowerInfo.watts) ?? "—"),
            ("Puissance allouée", power.allocatedW.map(PoEPowerInfo.watts) ?? "—"),
        ]
        if let available = power.availableW { rows.append(("Puissance disponible", PoEPowerInfo.watts(available))) }
        if let max = power.pseMaxAvailableW { rows.append(("Maximum du port", PoEPowerInfo.watts(max))) }
        if let status = power.poweringStatus { rows.append(("Alimentation", status)) }
        if let pairs = power.powerPairs { rows.append(("Paires", pairs == 1 ? "Signal (mode A)" : "Libres (mode B)")) }
        if let priority = power.priority { rows.append(("Priorité", priority.label.capitalized)) }
        if let source = power.powerSource { rows.append(("Source", source)) }
        if rows.count % 2 == 1 { rows.append(("Annonce", power.summary)) }
        return rows
    }

    private var note: String {
        guard let power else {
            if let legacySummary {
                return "Annonce PoE de cette capture\u{00A0}: \(legacySummary). Refaites une capture pour obtenir le détail (port PoE, courant fourni, classe)."
            }
            return "Le switch n’annonce aucun TLV PoE (802.3 Power via MDI, LLDP-MED, CDP)\u{00A0}: le port n’est probablement pas PoE, ou le switch ne le dit pas. Un Mac ne consomme pas de PoE."
        }
        if power.isPoEPort == true, power.isPowerDelivered != true {
            return "Le port peut fournir du PoE, mais n’alimente rien\u{00A0}: un Mac ne consomme pas de PoE. Un appareil alimenté (téléphone, borne, caméra) branché ici recevrait du courant."
        }
        if power.isPowerDelivered == true {
            return "Le switch dit fournir du courant sur ce port. Un Mac ne consomme pas de PoE\u{00A0}: vérifier qu’un appareil alimenté (injecteur, adaptateur) n’est pas intercalé."
        }
        return "Un Mac ne consomme pas de PoE\u{00A0}: la réponse dit seulement si le port du switch est PoE et s’il fournit du courant."
    }
}

/// Réponses « Oui / Non / Non annoncé » côte à côte, empilées en petite fenêtre.
private struct AdaptiveAnswers: View {
    let items: [(String, String, Bool?)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tiles }
            VStack(alignment: .leading, spacing: 8) { tiles }
        }
    }

    @ViewBuilder private var tiles: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            PoEAnswerTile(title: item.0, answer: item.1, value: item.2)
        }
    }
}

/// Tuile « Port PoE · Oui » : vert si oui, neutre si non, orangé si inconnu.
struct PoEAnswerTile: View {
    let title: String
    let answer: String
    let value: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(answer).font(Theme.bodySemibold).foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(background))
    }

    private var symbol: String {
        switch value {
        case true?: return "checkmark.circle.fill"
        case false?: return "minus.circle"
        case nil: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch value {
        case true?: return Theme.success
        case false?: return Theme.neutralText
        case nil: return Theme.warning
        }
    }

    private var background: Color {
        switch value {
        case true?: return Theme.successSoft
        case false?: return Theme.neutralSoft
        case nil: return Theme.warningSoft
        }
    }
}

/// Cellule de la colonne « PoE » du Scanner.
struct PoECell: View {
    let status: DevicePoEStatus?
    var dimmed = false

    var body: some View {
        HStack(spacing: 5) {
            if status?.isPowered == true {
                Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
            Text(status?.shortLabel ?? "—")
                .font(Theme.small)
                .foregroundStyle(status?.isPowered == true ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
        }
        .opacity(dimmed ? 0.55 : 1)
        .help(status.map { "\($0.switchName) · \($0.portName)\u{00A0}: \($0.detailLabel)" } ?? "Emplacement ou PoE du switch inconnu")
    }
}

extension PoEPowerInfo {
    /// Texte court pour l'encart « Ce Mac est branché sur… » : « port PoE (802.3at), aucun courant fourni ».
    var bannerText: String {
        var text: String
        switch isPoEPort {
        case true?: text = "port PoE" + (typeLabel.map { " (\($0))" } ?? "")
        case false?: text = "port sans PoE"
        case nil: text = "PoE non annoncé"
        }
        switch isPowerDelivered {
        case true?: text += ", courant fourni" + (allocatedW.map { " (\(PoEPowerInfo.watts($0)))" } ?? "")
        case false? where isPoEPort == true: text += ", aucun courant fourni"
        default: break
        }
        return text
    }
}

extension SwitchText {
    /// Ligne PoE d'un port (croquis Switch.dc.html, poeLine) : « Classe 4 · 18,4 W », « Aucune
    /// charge PoE », « PoE désactivé », « Port sans PoE » ; « — » pour un port inactif sans PoE.
    static func poeLine(_ iface: SNMPInterface, snapshot: SNMPSwitchSnapshot) -> String {
        if let port = snapshot.poePort(iface.index) {
            if port.isDelivering || port.adminEnabled == false || port.detection?.isFault == true { return port.summary }
            return iface.isUp ? port.summary : "—"
        }
        guard iface.isUp else { return "—" }
        return snapshot.poeDetails?.isEmpty == false ? "Port sans PoE" : "Aucune charge PoE"
    }
}

extension SwitchStore {
    /// PoE du port où l'appareil est localisé, d'après le dernier relevé SNMP de son switch.
    func poeStatus(for device: Device) -> DevicePoEStatus? {
        SNMPPoELookup.status(switchName: device.switchName, portName: device.switchPort, in: orderedSnapshots)
    }
}
