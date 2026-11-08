import NetScopeCore
import SwiftUI

/// Outil « IPv6 » (0.31.0) : adresses de ce Mac, voisins de la table NDP (lecture sans paquet,
/// sollicitation ff02::1 sur un clic), ping et traceroute IPv6.
struct IPv6ToolView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: ToolStore
    @ObservedObject private var model = IPv6Model.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            localBlock
            neighborsBlock
            pingBlock
        }
        .onAppear { model.refresh(interface: state.activeInterface?.name, state: state) }
    }

    // MARK: Ce Mac

    private var localBlock: some View {
        let status = model.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ce Mac").font(Theme.bodySemibold)
                Chip(text: "IPv6 \(status.level.label)", tone: status.level == .global ? .success : (status.level == .none ? .neutral : .warning))
                Spacer()
                Text(status.interface ?? state.activeInterface?.name ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            if status.addresses.isEmpty {
                Text("Aucune adresse IPv6 sur l’interface active.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            ForEach(status.addresses, id: \.self) { item in
                IPv6AddressLine(address: item.address, suffix: "/\(item.prefixLength)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Voisins

    private var neighborsBlock: some View {
        let byMAC = IPv6Attachment.addressesByMAC(model.neighbors)
        let macs = byMAC.keys.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            ToolAdaptiveRow(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voisins IPv6 (table NDP)").font(Theme.bodySemibold)
                    Text(neighborSummary(macs.count)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button("Relire la table") { model.refresh(interface: state.activeInterface?.name, state: state) }
                        .buttonStyle(.secondary)
                        .help("Lit la table des voisins du système, sans rien envoyer")
                    Button(model.isSoliciting ? "Sollicitation…" : "Ping ff02::1 sur \(state.activeInterface?.name ?? "en0")") {
                        model.solicit(state: state)
                    }
                    .buttonStyle(.secondary)
                    .disabled(model.isSoliciting)
                    .help("Ping ICMPv6 de tous les nœuds du lien\u{00A0}: ceux qui répondent entrent dans la table NDP")
                }
                .controlSize(.small)
                .fixedSize()
            }
            VStack(spacing: 0) {
                ForEach(macs, id: \.self) { mac in
                    neighborRow(mac: mac, addresses: byMAC[mac] ?? [])
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func neighborSummary(_ count: Int) -> String {
        var text = count == 0 ? "Aucun voisin IPv6 dans la table." : "\(count) appareil\(count > 1 ? "s" : "") · \(model.neighbors.count) adresses"
        if let solicited = model.solicited { text += " · \(solicited.count) réponse\(solicited.count > 1 ? "s" : "") à ff02::1" }
        let orphans = model.unmatched(in: state).map(\.mac)
        let orphanCount = Set(orphans).count
        if orphanCount > 0 { text += " · \(orphanCount) sans adresse IPv4 connue" }
        return text
    }

    private func neighborRow(mac: MACAddress, addresses: [IPv6Address]) -> some View {
        let device = state.devices.first { $0.mac == mac }
        let router = model.neighbors.contains { $0.mac == mac && $0.isRouter }
        let info = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(device?.displayName ?? "Appareil IPv6 seulement").font(Theme.small.weight(.semibold))
                    .foregroundStyle(device == nil ? Theme.textSecondary : Theme.text).lineLimit(1)
                if router { Chip(text: "Routeur", tone: .accent) }
            }
            Text([device?.ip.description, mac.formatted(.upperColon)].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(device?.vendorLabel ?? OUIDatabase.builtIn.label(for: mac))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        let list = VStack(alignment: .leading, spacing: 3) {
            ForEach(addresses, id: \.self) { address in
                IPv6AddressLine(address: address, compact: true)
            }
        }
        .fixedSize()
        let open = Group {
            if let device {
                Button("Fiche") { state.showDevice(device.id) }.buttonStyle(.secondary).controlSize(.small).fixedSize()
            }
        }
        // Adresses jamais coupées : à droite de l'appareil quand tout tient, sinon dessous.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                info.frame(width: 250, alignment: .leading)
                list
                Spacer(minLength: 0)
                open
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    info
                    Spacer(minLength: 8)
                    open
                }
                list
            }
        }
        .padding(.vertical, 7)
    }

    // MARK: Ping et traceroute

    private var pingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ping et traceroute IPv6").font(Theme.bodySemibold)
            ToolAdaptiveRow(spacing: 8) {
                ToolTextField(placeholder: "2001:4860:4860::8888 ou fe80::1%en0", text: $model.target,
                              invalid: model.parsedTarget == nil, height: 32)
                    .frame(minWidth: 260)
                HStack(spacing: 6) {
                    Button(model.isPinging ? "Ping…" : "Ping (4)") {
                        model.ping()
                        store.record(command: "ping6 -c 4 \(model.target)")
                    }
                    .buttonStyle(.secondary).disabled(model.isPinging)
                    Button(model.isTracing ? "Traceroute…" : "Traceroute") {
                        model.runTrace()
                        store.record(command: "traceroute6 -n -I \(model.target)")
                    }
                    .buttonStyle(.secondary).disabled(model.isTracing)
                    Button("Ping continu") { state.sendToPing(model.target) }
                        .buttonStyle(.secondary)
                        .disabled(model.parsedTarget == nil)
                }
                .fixedSize()
            }
            if let message = model.message {
                ToolNotice(tone: .warning, message: message)
            }
            if !model.pingResults.isEmpty {
                pingSummary
            }
            if let trace = model.trace {
                IPv6TraceTable(hops: trace)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var pingSummary: some View {
        let results = model.pingResults
        let times = results.compactMap(\.rttMs)
        let lost = results.count - times.count
        let average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                Text(result.rttMs.map { "Réponse de \(model.target)\u{00A0}: icmp_seq=\(index + 1) temps=\(PingFormat.decimal($0)) ms" }
                     ?? "icmp_seq=\(index + 1)\u{00A0}: \(result.failure?.label ?? "délai dépassé")")
                    .font(Theme.mono(12)).foregroundStyle(result.rttMs == nil ? Theme.critical : Theme.text)
            }
            Text("\(results.count) envoyés · \(times.count) reçus · \(lost == 0 ? "0\u{00A0}%" : "\(lost * 100 / max(results.count, 1))\u{00A0}%") de perte"
                 + (average.map { " · moyenne \(PingFormat.decimal($0)) ms" } ?? ""))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
        .textSelection(.enabled)
    }
}

/// Une adresse IPv6 avec sa portée (pastille) : fiche Appareil, outil IPv6.
struct IPv6AddressLine: View {
    let address: IPv6Address
    var suffix = ""
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Chip(text: label, tone: tone)
                .frame(width: compact ? 78 : 96, alignment: .leading)
            Text(address.description + suffix).font(Theme.mono(compact ? 11 : 12)).foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize()
                .textSelection(.enabled)
            if address.embeddedMAC != nil && address.scope != .linkLocal {
                Text("EUI-64").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .help("\(address.scope.label) · \(address.scope.block) · forme complète \(address.expanded)")
    }

    private var label: String {
        address.scope == .documentation ? "Globale" : address.scope.shortLabel
    }

    private var tone: Tone {
        switch address.scope {
        case .global, .documentation: return .accent
        case .uniqueLocal: return .success
        default: return .neutral
        }
    }
}

/// Tableau d'un traceroute IPv6 (outil IPv6 et ping continu).
struct IPv6TraceTable: View {
    let hops: [IPv6TraceHop]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                header("N°", width: 28, trailing: true)
                header("Adresse", width: nil)
                header("Meilleur", width: 70, trailing: true)
                header("Moy", width: 60, trailing: true)
                header("Perte", width: 50, trailing: true)
            }
            .padding(.vertical, 6)
            Rectangle().fill(Theme.border).frame(height: 1)
            if hops.isEmpty {
                Text("Aucun saut lu.").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.vertical, 8)
            }
            ForEach(hops) { hop in
                HStack(spacing: 10) {
                    Text("\(hop.ttl)").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).frame(width: 28, alignment: .trailing)
                    Text(hop.address?.description ?? "???").font(Theme.mono(12)).foregroundStyle(hop.address == nil ? Theme.textTertiary : Theme.text)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Text(hop.bestMs.map { PingFormat.decimal($0) } ?? "—").font(Theme.mono(12)).frame(width: 70, alignment: .trailing)
                    Text(hop.averageMs.map { PingFormat.decimal($0) } ?? "—").font(Theme.mono(12)).frame(width: 60, alignment: .trailing)
                    let total = hop.rttsMs.count + hop.lost
                    Text(total == 0 ? "—" : "\(hop.lost * 100 / total)\u{00A0}%").font(Theme.mono(12))
                        .foregroundStyle(hop.lost > 0 ? Theme.critical : Theme.textSecondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func header(_ text: String, width: CGFloat?, trailing: Bool = false) -> some View {
        Text(text.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Traceroute IPv6 d'une cible ICMPv6 du ping continu (le MTR IPv4 ne s'applique pas).
struct PingIPv6TracePanel: View {
    let target: PingTarget
    @ObservedObject private var model = IPv6Model.shared

    var body: some View {
        let isCurrent = model.traceTarget == target.host
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Traceroute IPv6").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    (Text("vers ").foregroundColor(Theme.textSecondary)
                        + Text(target.host).font(Theme.mono(12)).foregroundColor(Theme.text)
                        + Text(" · traceroute6, trois sondes ICMPv6 par saut").foregroundColor(Theme.textSecondary))
                        .font(Theme.small).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    model.trace(to: target.host)
                } label: {
                    Label(model.isTracing ? "En cours…" : "Lancer", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PingSmallButtonStyle(prominent: true))
                .disabled(model.isTracing)
            }
            if isCurrent, let hops = model.trace {
                IPv6TraceTable(hops: hops)
            } else {
                Text(model.isTracing ? "Traceroute en cours…" : "Lancez le traceroute pour voir le chemin IPv6 jusqu’à la cible.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Cellule IPv6 du Scanner : l'adresse la plus utile (globale, ULA, lien local) et le nombre d'autres.
struct ScanIPv6Cell: View {
    let addresses: [IPv6Address]

    var body: some View {
        if let main = Self.main(addresses) {
            HStack(spacing: 5) {
                Text(main.description).font(Theme.mono(12)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if addresses.count > 1 {
                    Text("+\(addresses.count - 1)").font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize()
                }
            }
            .help(addresses.map { "\($0.scope.label)\u{00A0}: \($0)" }.joined(separator: "\n"))
        } else {
            Text("—").font(Theme.mono(12)).foregroundStyle(Theme.textTertiary)
        }
    }

    static func main(_ addresses: [IPv6Address]) -> IPv6Address? {
        addresses.first { $0.scope == .global || $0.scope == .documentation }
            ?? addresses.first { $0.scope == .uniqueLocal } ?? addresses.first
    }
}

extension Device {
    /// Tri de la colonne IPv6 : adresse principale ; sans adresse, en dernier.
    var scanSortIPv6: String {
        ScanIPv6Cell.main(ipv6 ?? []).map(\.expanded) ?? "~"
    }
}
