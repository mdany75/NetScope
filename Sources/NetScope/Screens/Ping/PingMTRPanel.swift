import NetScopeCore
import SwiftUI

/// Tableau MTR / traceroute vers la cible sélectionnée.
struct PingMTRPanel: View {
    @ObservedObject var controller: PingController
    let target: PingTarget

    /// Colonnes du tableau (titre, largeur, alignement) ; l'hôte prend la place restante.
    private static let columns: [(String, CGFloat?, Alignment)] = [
        ("N°", 28, .trailing), ("Hôte", nil, .leading), ("IP", 112, .leading), ("Perte", 56, .trailing),
        ("Envoyés", 64, .trailing), ("Dernier", 60, .trailing), ("Moy", 46, .trailing),
        ("Meilleur", 66, .trailing), ("Pire", 44, .trailing), ("Écart-type", 78, .trailing),
    ]

    var body: some View {
        let report = controller.mtrReport
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MTR / Traceroute").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    (Text("vers ").foregroundColor(Theme.textSecondary)
                        + Text(target.addressLabel).font(Theme.mono(12)).foregroundColor(Theme.text)
                        + Text(" · \(info(report))").foregroundColor(Theme.textSecondary))
                        .font(Theme.small)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if controller.isMTRRunning {
                    Button { controller.stopMTR() } label: {
                        Label("Arrêter", systemImage: "stop.fill").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PingSmallButtonStyle())
                } else {
                    Button { controller.startMTR() } label: {
                        Label("Lancer MTR", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PingSmallButtonStyle(prominent: true))
                    .disabled(target.address == nil)
                }
                Button("Résolution DNS : \(controller.resolveHopNames ? "oui" : "non")") {
                    controller.resolveHopNames.toggle()
                }
                .buttonStyle(PingSmallButtonStyle())
                .help("Afficher le nom inverse (PTR) de chaque saut")
                Button("Copier le rapport") { controller.copyMTRReport() }
                    .buttonStyle(PingSmallButtonStyle())
                    .disabled(report == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            header
            if let report, !report.hops.isEmpty {
                ForEach(report.hops, id: \.ttl) { hop in row(hop) }
            } else {
                Text(placeholder)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13))
                Text(note(report)).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    /// En-tête compact (10 pt) pour que les dix colonnes tiennent dans la colonne de gauche.
    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Self.columns, id: \.0) { column in
                let label = Text(column.0.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .minimumScaleFactor(0.85)
                if let width = column.1 {
                    label.frame(width: width, alignment: column.2)
                } else {
                    label.frame(minWidth: 120, maxWidth: .infinity, alignment: column.2)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func row(_ hop: PingMTRHop) -> some View {
        let stats = hop.stats
        let name = hostname(for: hop)
        return HStack(spacing: 0) {
            cell("\(hop.ttl)", width: 28, alignment: .trailing, color: Theme.textSecondary)
            Text(name)
                .font(.system(size: 12, weight: hop.isDestination ? .semibold : .regular))
                .foregroundStyle(name.hasPrefix("(") || name == "???" ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .help(name)
            cell(hop.address?.description ?? "—", width: 112, alignment: .leading, mono: true, size: 11)
            cell(PingFormat.percent(stats.lossPercent), width: 56, alignment: .trailing, mono: true,
                 color: pingLossColor(stats.lossPercent), bold: stats.lossPercent > 0)
            cell("\(stats.sent)", width: 64, alignment: .trailing, mono: true)
            cell(PingFormat.decimal(stats.last), width: 60, alignment: .trailing, mono: true)
            cell(PingFormat.decimal(stats.average), width: 46, alignment: .trailing, mono: true, bold: true)
            cell(PingFormat.decimal(stats.best), width: 66, alignment: .trailing, mono: true)
            cell(PingFormat.decimal(stats.worst), width: 44, alignment: .trailing, mono: true)
            cell(PingFormat.decimal(stats.standardDeviation), width: 78, alignment: .trailing, mono: true)
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 8)
        .background(hop.isDestination ? Color(hex: 0xF8FAFF) : Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .contextMenu {
            if let address = hop.address {
                Button("Copier l’adresse") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.description, forType: .string)
                }
                Button("Ajouter au ping continu") { controller.add(address.description) }
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment, mono: Bool = false,
                      color: Color = Theme.text, bold: Bool = false, size: CGFloat = 12) -> some View {
        Text(text)
            .font(mono ? Theme.mono(size, weight: bold ? .semibold : .regular) : .system(size: size))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: alignment)
    }

    private func hostname(for hop: PingMTRHop) -> String {
        guard let address = hop.address else { return "???" }
        if hop.isDestination, controller.resolveHopNames, controller.hostnames[address] == nil,
           target.name != target.addressLabel {
            return target.name
        }
        guard controller.resolveHopNames else { return address.description }
        return controller.hostnames[address] ?? "(sans PTR)"
    }

    private func info(_ report: PingMTRReport?) -> String {
        guard let report, report.cycles > 0 else { return controller.isMTRRunning ? "découverte du chemin…" : "pas encore lancé" }
        let hops = report.hops.count
        return "\(hops) \(hops > 1 ? "sauts" : "saut") · \(report.cycles) cycles · ICMP"
    }

    private var placeholder: String {
        if let error = controller.mtrError { return error }
        if controller.isMTRRunning { return "Découverte du chemin en cours (TTL 1 à 30)…" }
        return "Cliquer sur « Lancer MTR » pour suivre chaque saut du chemin vers \(target.addressLabel) : perte, latence et écart-type par routeur."
    }

    private func note(_ report: PingMTRReport?) -> String {
        guard let report, !report.hops.isEmpty else {
            return "Le MTR envoie un Echo Request par saut et par cycle (TTL croissant) ; chaque routeur répond par « Time Exceeded »."
        }
        if report.hops.count == 1 {
            return "Même sous-réseau : 1 seul saut L3. Le chemin L2 (switchs et ports) se lit sur l’écran Switchs et ports."
        }
        if report.hops.count == 2 {
            return "Routage par la passerelle. Une perte sur le dernier saut seulement pointe vers l’appareil ou son port de switch, pas vers le cœur."
        }
        return "Une perte sur un saut intermédiaire qui ne se propage pas aux sauts suivants vient d’une limitation ICMP du routeur, pas d’une vraie perte sur le chemin."
    }
}

/// Petit bouton du croquis (hauteur 28, 12 pt).
struct PingSmallButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(prominent ? (configuration.isPressed ? Theme.accentStrong : Theme.accent)
                                : (configuration.isPressed ? Theme.panelMuted : Theme.panel)))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(prominent ? Color.clear : Theme.borderStrong))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}
